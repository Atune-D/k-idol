#!/usr/bin/env ruby

require "date"
require "pathname"
require "time"
require "yaml"

ACTIVE_STATUSES = %w[draft verified adopted].freeze
EXCLUDED_FILES = %w[README.md AGENTS.md PREFERENCE_INDEX.md].freeze

root = Pathname.new(ARGV.fetch(0, File.expand_path("~/.claude/practices"))).expand_path
index_path = root.join("PREFERENCE_INDEX.md")

abort "Knowledge base not found: #{root}" unless root.directory?
abort "Routing index not found: #{index_path}" unless index_path.file?

def frontmatter(path)
  content = path.read
  parts = content.split(/^---\s*$\n/)
  return nil unless parts.length >= 3

  YAML.safe_load(
    parts[1],
    permitted_classes: [Date, Time],
    aliases: false,
  )
rescue Psych::SyntaxError => error
  abort "Invalid frontmatter in #{path}: #{error.message}"
end

canonical = {}
deprecated = {}
errors = []

root.glob("**/*.md").sort.each do |path|
  relative_path = path.relative_path_from(root).to_s
  next if EXCLUDED_FILES.include?(relative_path)
  next if File.basename(relative_path) == "README.md"
  next if %w[templates/ inbox/ field-notes/].any? { |prefix| relative_path.start_with?(prefix) }

  metadata = frontmatter(path)
  next unless metadata

  if ACTIVE_STATUSES.include?(metadata["status"])
    if relative_path.start_with?("archive/")
      errors << "Active canonical must not live under archive: #{relative_path}"
    else
      canonical[relative_path] = metadata["status"]
    end
  elsif metadata["status"] == "deprecated"
    deprecated[relative_path] = metadata
  end
end

deprecated.each do |relative_path, metadata|
  replacement = metadata["replaced-by"]

  if !replacement.is_a?(String) || replacement.strip.empty?
    errors << "Deprecated document is missing replaced-by: #{relative_path}"
  elsif !canonical.key?(replacement)
    errors << "Deprecated replacement is not an active canonical: #{relative_path} -> #{replacement}"
  end
end

routes = {}
route_ids = {}

index_path.each_line.with_index(1) do |line, line_number|
  next unless line.start_with?("| `")

  cells = line.split("|").map(&:strip).reject(&:empty?)
  if cells.length != 6
    errors << "Routing row must have 6 columns at line #{line_number}"
    next
  end

  id = cells[0][/\A`([^`]+)`\z/, 1]
  status = cells[4][/\A`(draft|verified|adopted)`\z/, 1]
  canonical_match = cells[5].match(/\A\[`([^`]+)`\]\(([^)]+)\)\z/)

  unless id && status && canonical_match
    errors << "Malformed routing row at line #{line_number}"
    next
  end

  label_path = canonical_match[1]
  target_path = canonical_match[2]
  errors << "Task signals must not be empty for #{id}" if cells[1].empty? || cells[1] == "-"
  errors << "Must-read condition must not be empty for #{id}" if cells[2].empty? || cells[2] == "-"
  errors << "Skip condition must not be empty for #{id}" if cells[3].empty? || cells[3] == "-"
  errors << "Routing label/path mismatch for #{id}" unless label_path == target_path
  errors << "Duplicate routing ID: #{id}" if route_ids.key?(id)
  errors << "Duplicate canonical route: #{target_path}" if routes.key?(target_path)

  route_ids[id] = line_number
  routes[target_path] = status

  if Pathname.new(target_path).absolute?
    errors << "Routing path must be relative: #{target_path}"
  elsif !root.join(target_path).file?
    errors << "Routing target does not exist: #{target_path}"
  end
end

(canonical.keys - routes.keys).sort.each do |path|
  errors << "Active canonical is missing from routing index: #{path}"
end

(routes.keys - canonical.keys).sort.each do |path|
  errors << "Routing entry does not point to an active canonical: #{path}"
end

(canonical.keys & routes.keys).sort.each do |path|
  next if canonical[path] == routes[path]

  errors << "Status mismatch for #{path}: canonical=#{canonical[path]} index=#{routes[path]}"
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Preference index valid: #{canonical.length} active canonical documents, #{routes.length} routing entries, #{deprecated.length} deprecated documents"
