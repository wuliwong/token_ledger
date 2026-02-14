# frozen_string_literal: true

module TokenLedger
  class LedgerEntry < ActiveRecord::Base
    self.table_name = "ledger_entries"

    belongs_to :account, class_name: "TokenLedger::LedgerAccount", required: true
    belongs_to :ledger_transaction, class_name: "TokenLedger::LedgerTransaction", foreign_key: "transaction_id", required: true

    validates :entry_type, presence: true, inclusion: { in: %w[debit credit] }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
  end
end
