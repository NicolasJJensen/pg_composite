require_relative "lib/pg_composite/version"

Gem::Specification.new do |spec|
  spec.name = "pg_composite"
  spec.version = PgComposite::VERSION
  spec.authors = ["Nicolas J Jensen"]
  spec.email = ["nicolasjensen9@gmail.com"]
  spec.summary = "Typed PostgreSQL composites, member queries, and controller parameter casting"
  spec.description = <<~DESCRIPTION
    PgComposite maps a PostgreSQL composite column to a Ruby value object with declared, typed members.
    Assign a value object or a hash to an Active Record attribute, and the gem casts, serializes, and
    tracks in-place changes like any other attribute. Queries reach individual members through an
    ordinary where hash or through Arel, and an optional controller concern casts nested request
    parameters before the action runs.
  DESCRIPTION
  spec.license = "MIT"
  spec.homepage = "https://github.com/NicolasJJensen/pg_composite"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |file| File.file?(file) }
  end
  spec.require_paths = ["lib"]
  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "pg", ">= 1.1", "< 2.0"
  spec.add_development_dependency "actionpack", ">= 7.0", "< 9.0"
end
