# frozen_string_literal: true

class CreateLedgerTables < ActiveRecord::Migration[7.0]
  def change
    create_table :ledger_accounts do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.bigint :current_balance, default: 0, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps

      t.index :code, unique: true
      t.index :current_balance
    end

    create_table :ledger_transactions do |t|
      t.string :transaction_type, null: false
      t.string :description
      t.references :owner, polymorphic: true
      t.bigint :parent_transaction_id
      t.string :external_source
      t.string :external_id
      t.jsonb :metadata, default: {}, null: false
      t.timestamps

      t.index [:external_source, :external_id], unique: true, where: "external_source IS NOT NULL"
      t.index [:owner_type, :owner_id, :created_at]
      t.index [:transaction_type, :created_at]
      t.index :parent_transaction_id
    end

    # Add foreign key constraint for parent-child transaction relationships
    add_foreign_key :ledger_transactions, :ledger_transactions,
                    column: :parent_transaction_id,
                    on_delete: :restrict

    create_table :ledger_entries do |t|
      t.references :account, null: false, foreign_key: { to_table: :ledger_accounts, on_delete: :restrict }
      t.references :transaction, null: false, foreign_key: { to_table: :ledger_transactions, on_delete: :restrict }
      t.string :entry_type, null: false
      t.bigint :amount, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps

      t.index [:account_id, :created_at]
      t.index [:transaction_id, :entry_type]
    end

    # Add CHECK constraints for data integrity
    add_check_constraint :ledger_entries, "amount > 0", name: "positive_amount"
    add_check_constraint :ledger_entries, "entry_type IN ('debit', 'credit')", name: "valid_entry_type"
    add_check_constraint :ledger_transactions,
      "transaction_type IN ('deposit', 'spend', 'reserve', 'capture', 'release', 'adjustment')",
      name: "valid_transaction_type"
    add_check_constraint :ledger_transactions,
      "(external_source IS NULL AND external_id IS NULL) OR (external_source IS NOT NULL AND external_id IS NOT NULL)",
      name: "external_source_id_consistency"
  end
end
