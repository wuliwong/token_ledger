# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "token_ledger"

require "minitest/autorun"
require "active_record"
require "fileutils"

# Setup file-based SQLite database for testing (required for thread safety)
db_path = File.expand_path("../tmp/test.db", __dir__)
FileUtils.mkdir_p(File.dirname(db_path))
File.delete(db_path) if File.exist?(db_path)

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: db_path,
  pool: 20
)

# Enable Write-Ahead Logging for better concurrency
ActiveRecord::Base.connection.execute("PRAGMA journal_mode = WAL")
ActiveRecord::Base.connection.execute("PRAGMA busy_timeout = 30000") # 30 seconds for thread tests
ActiveRecord::Base.connection.execute("PRAGMA synchronous = NORMAL")
ActiveRecord::Base.connection.execute("PRAGMA cache_size = 10000")

# Clean up database file after tests
Minitest.after_run do
  File.delete(db_path) if File.exist?(db_path)
end

# Load schema
ActiveRecord::Schema.define do
  create_table :ledger_accounts, force: true do |t|
    t.string :code, null: false
    t.string :name, null: false
    t.bigint :current_balance, default: 0, null: false
    t.json :metadata, default: {}, null: false
    t.timestamps

    t.index :code, unique: true
    t.index :current_balance
  end

  create_table :ledger_transactions, force: true do |t|
    t.string :transaction_type, null: false
    t.string :description
    t.string :owner_type
    t.bigint :owner_id
    t.string :external_source
    t.string :external_id
    t.bigint :parent_transaction_id
    t.json :metadata, default: {}, null: false
    t.timestamps

    t.index [:owner_type, :owner_id, :created_at]
    t.index [:transaction_type, :created_at]
    t.index :parent_transaction_id
  end

  add_foreign_key :ledger_transactions, :ledger_transactions,
                  column: :parent_transaction_id,
                  on_delete: :nullify

  create_table :ledger_entries, force: true do |t|
    t.references :account, null: false
    t.references :transaction, null: false
    t.string :entry_type, null: false
    t.bigint :amount, null: false
    t.json :metadata, default: {}, null: false
    t.timestamps

    t.index [:account_id, :created_at]
    t.index [:transaction_id, :entry_type]
  end

  # Add foreign key constraints with explicit on_delete behavior
  add_foreign_key :ledger_entries, :ledger_accounts,
                  column: :account_id,
                  on_delete: :restrict
  add_foreign_key :ledger_entries, :ledger_transactions,
                  column: :transaction_id,
                  on_delete: :restrict

  # Add CHECK constraints for data integrity
  execute "CREATE TABLE IF NOT EXISTS temp_check AS SELECT 1"  # Ensures SQLite compatibility
  execute <<-SQL
    CREATE TRIGGER IF NOT EXISTS check_positive_amount
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW
    WHEN NEW.amount <= 0
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: positive_amount');
    END;
  SQL

  execute <<-SQL
    CREATE TRIGGER IF NOT EXISTS check_valid_entry_type
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW
    WHEN NEW.entry_type NOT IN ('debit', 'credit')
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: valid_entry_type');
    END;
  SQL

  execute <<-SQL
    CREATE TRIGGER IF NOT EXISTS check_valid_transaction_type
    BEFORE INSERT ON ledger_transactions
    FOR EACH ROW
    WHEN NEW.transaction_type NOT IN ('deposit', 'spend', 'reserve', 'capture', 'release', 'adjustment')
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: valid_transaction_type');
    END;
  SQL

  execute <<-SQL
    CREATE TRIGGER IF NOT EXISTS check_external_source_id_consistency
    BEFORE INSERT ON ledger_transactions
    FOR EACH ROW
    WHEN NOT ((NEW.external_source IS NULL AND NEW.external_id IS NULL) OR (NEW.external_source IS NOT NULL AND NEW.external_id IS NOT NULL))
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: external_source_id_consistency');
    END;
  SQL

  create_table :users, force: true do |t|
    t.string :email
    t.bigint :cached_balance, default: 0, null: false
    t.timestamps
  end
end

# Simple User model for testing
class User < ActiveRecord::Base
  has_many :ledger_transactions, as: :owner, class_name: "TokenLedger::LedgerTransaction"

  def balance
    cached_balance
  end
end
