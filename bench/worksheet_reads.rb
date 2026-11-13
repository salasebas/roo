# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"

SCENARIOS = {
  "sparse-parse" => ["sparse", :parse, false],
  "sparse-headers" => ["sparse", :headers, false],
  "sparse-each" => ["sparse", :each, false],
  "sparse-csv" => ["sparse-csv", :csv, false],
  "narrow-cells" => ["narrow", :cells, false],
  "wide-padding" => ["wide", :stream, false],
  "dense-parse" => ["dense", :parse, false],
  "dense-headers" => ["dense", :headers, false],
  "dense-csv" => ["dense", :csv, false],
  "dense-csv-warm" => ["dense", :csv, :warm],
  "dense-projection" => ["dense", :projection, false],
  "dense-projection-loaded" => ["dense", :projection, :loaded],
  "dense-projection-warm" => ["dense", :projection, :warm],
  "mixed-csv" => ["mixed", :csv, false],
  "small-parse" => ["small", :parse, false],
  "small-csv" => ["small", :csv, false]
}.freeze

def read_workbook(book, operation)
  case operation
  when :parse then book.parse
  when :headers then book.parse(headers: true)
  when :each then book.each(headers: true).to_a
  when :csv then book.to_csv
  when :projection then book.parse(first: /^h1$/, last: /^h20$/)
  when :cells then book.sheet_for(nil).cells
  when :stream
    digest = Digest::SHA256.new
    book.each_row_streaming(pad_cells: true) do |row|
      digest << Marshal.dump([row.size, row.compact.map { |cell| [cell.coordinate, cell.value] }])
    end
    digest.hexdigest
  end
end

if ARGV.first == "--worker"
  _, library, path, scenario = ARGV
  $LOAD_PATH.unshift(File.expand_path(library))
  require "roo"
  raise "roo-calamine is loaded" if $LOADED_FEATURES.any? { |feature| feature.include?("calamine") }

  _, operation, warm = SCENARIOS.fetch(scenario)
  book = nil
  if warm
    book = Roo::Excelx.new(path)
    book.last_row
    book.first_column
    book.last_column
    read_workbook(book, operation) if warm == :warm
  end
  GC.start
  gc_before = GC.stat
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  book ||= Roo::Excelx.new(path)
  result = read_workbook(book, operation)
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  gc_after = GC.stat
  allocated = gc_after[:total_allocated_objects] - gc_before[:total_allocated_objects]
  puts JSON.generate(seconds: seconds, allocated_objects: allocated,
    digest: Digest::SHA256.hexdigest(Marshal.dump(result)), ruby: RUBY_DESCRIPTION,
    versions: %w[nokogiri rubyzip].to_h { |name| [name, Gem.loaded_specs.fetch(name).version.to_s] },
    library: $LOADED_FEATURES.find { |feature| feature.end_with?("/lib/roo.rb") },
    minor_gc: gc_after[:minor_gc_count] - gc_before[:minor_gc_count],
    major_gc: gc_after[:major_gc_count] - gc_before[:major_gc_count],
    gc_ms: gc_after[:time] - gc_before[:time])
  book.close
  exit
end

def column_name(column)
  result = +""
  while column.positive?
    column, remainder = (column - 1).divmod(26)
    result.prepend((65 + remainder).chr)
  end
  result
end

def generate_fixtures(directory)
  require "fileutils"
  require "zip"

  { "sparse" => [10_000, 200], "sparse-csv" => [10_000, 40],
    "narrow" => [30_000, 2], "wide" => [10_000, 500],
    "dense" => [10_000, 20], "mixed" => [10_000, 20], "small" => [40, 8] }.each do |name, (rows, width)|
    path = File.join(directory, "#{name}.xlsx")
    FileUtils.cp(File.expand_path("../test/files/only_one_sheet.xlsx", __dir__), path)
    letters = (1..width).map { |column| column_name(column) }
    xml = +'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
    1.upto(rows) do |row|
      columns = name.start_with?("sparse") && row > 1 || name == "wide" ? [1, width] : (1..width)
      xml << %(<row r="#{row}">)
      columns.each do |column|
        coordinate = "#{letters[column - 1]}#{row}"
        xml << if row == 1
          %(<c r="#{coordinate}" t="inlineStr"><is><t>h#{column}</t></is></c>)
        elsif name == "mixed" && column % 3 == 0
          %(<c r="#{coordinate}" t="inlineStr"><is><t>é &quot;#{row}&quot;, value</t></is></c>)
        elsif name == "mixed" && column % 3 == 1
          %(<c r="#{coordinate}" t="b"><v>#{row % 2}</v></c>)
        else
          %(<c r="#{coordinate}"><v>#{row * width + column}</v></c>)
        end
      end
      xml << "</row>"
    end
    xml << "</sheetData></worksheet>"
    Zip::File.open(path) { |zip| zip.get_output_stream("xl/worksheets/sheet1.xml") { |io| io.write(xml) } }
  end
end

def median(values)
  values.sort.fetch(values.length / 2)
end

options = { candidate: File.expand_path("..", __dir__), pairs: 5, scenarios: SCENARIOS.keys }
OptionParser.new do |parser|
  parser.banner = "ruby bench/worksheet_reads.rb --baseline CHECKOUT [options]"
  parser.on("--baseline PATH") { |path| options[:baseline] = File.expand_path(path) }
  parser.on("--candidate PATH") { |path| options[:candidate] = File.expand_path(path) }
  parser.on("--pairs N", Integer) { |count| options[:pairs] = count }
  parser.on("--scenarios LIST") { |list| options[:scenarios] = list.split(",") }
  parser.on("--output PATH") { |path| options[:output] = path }
end.parse!
abort "--baseline is required" unless options[:baseline]
abort "--pairs must be positive" unless options[:pairs].positive?
options[:scenarios].each { |name| SCENARIOS.fetch(name) }

samples = []
Dir.mktmpdir("roo-worksheet-bench") do |directory|
  generate_fixtures(directory)
  options[:scenarios].each do |scenario|
    fixture, = SCENARIOS.fetch(scenario)
    0.upto(options[:pairs]) do |pair|
      variants = pair.even? ? %i[baseline candidate] : %i[candidate baseline]
      observations = variants.map do |variant|
        command = [RbConfig.ruby, __FILE__, "--worker", File.join(options.fetch(variant), "lib"),
          File.join(directory, "#{fixture}.xlsx"), scenario]
        command.unshift("/usr/bin/time", "-l") if RUBY_PLATFORM.include?("darwin")
        stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil }, *command)
        raise "#{variant}/#{scenario}: #{stderr}\n#{stdout}" unless status.success?

        JSON.parse(stdout).merge("scenario" => scenario, "variant" => variant.to_s,
          "pair" => pair, "warmup" => pair.zero?,
          "peak_rss_bytes" => stderr[/^\s*(\d+)\s+maximum resident set size/, 1]&.to_i)
      end
      raise "Different results: #{scenario}" unless observations.map { |sample| sample.fetch("digest") }.uniq.one?

      samples.concat(observations)
      File.write(options[:output], JSON.pretty_generate(samples)) if options[:output]
    end
    measured = samples.select { |sample| sample["scenario"] == scenario && !sample["warmup"] }
    baseline = measured.select { |sample| sample["variant"] == "baseline" }
    candidate = measured.select { |sample| sample["variant"] == "candidate" }
    before = median(baseline.map { |sample| sample.fetch("seconds") })
    after = median(candidate.map { |sample| sample.fetch("seconds") })
    puts format("%-24s %.6f -> %.6f s (%+.1f%% less time), %d -> %d objects", scenario, before, after,
      100 * (1 - after / before), median(baseline.map { |sample| sample.fetch("allocated_objects") }),
      median(candidate.map { |sample| sample.fetch("allocated_objects") }))
    $stdout.flush
  end
end
