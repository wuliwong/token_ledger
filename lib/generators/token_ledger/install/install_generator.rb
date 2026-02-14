# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module TokenLedger
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      class_option :owner_model, type: :string, default: "User",
        desc: "The model that owns tokens (e.g., User, Team)"

      source_root File.expand_path("templates", __dir__)

      def copy_ledger_migration
        migration_template "create_ledger_tables.rb",
          "db/migrate/create_ledger_tables.rb"
      end

      def copy_owner_migration
        @owner_class_name = options[:owner_model]
        @owner_table_name = @owner_class_name.tableize

        migration_template "add_cached_balance_to_owner.rb",
          "db/migrate/add_cached_balance_to_#{@owner_table_name}.rb"
      end

      def show_readme
        readme "README" if behavior == :invoke
      end

      private

      def owner_class_name
        @owner_class_name
      end

      def owner_table_name
        @owner_table_name
      end
    end
  end
end
