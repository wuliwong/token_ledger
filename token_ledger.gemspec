# frozen_string_literal: true

require_relative "lib/token_ledger/version"

Gem::Specification.new do |spec|
  spec.name = "token_ledger"
  spec.version = TokenLedger::VERSION
  spec.authors = ["Patrick Bradley"]
  spec.email = ["patrickbradley777@gmail.com"]

  spec.summary = "Double-entry token ledger for Rails applications"
  spec.description = "A Rails engine providing thread-safe, double-entry accounting for user tokens with reserve/capture semantics and scoped idempotency"
  spec.homepage = "https://github.com/wuliwong/token_ledger"
  spec.required_ruby_version = ">= 3.0.0"
  spec.license = "MIT"

  spec.metadata["homepage_uri"] = "https://github.com/wuliwong/token_ledger#readme"
  spec.metadata["source_code_uri"] = "https://github.com/wuliwong/token_ledger"
  spec.metadata["bug_tracker_uri"] = "https://github.com/wuliwong/token_ledger/issues"
  spec.metadata["changelog_uri"] = "https://github.com/wuliwong/token_ledger/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir["lib/**/*", "sig/**/*", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Rails dependencies
  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"

  # Development dependencies
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "minitest", "~> 5.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
