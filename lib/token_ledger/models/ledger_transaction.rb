# frozen_string_literal: true

module TokenLedger
  class LedgerTransaction < ActiveRecord::Base
    self.table_name = "ledger_transactions"

    belongs_to :owner, polymorphic: true, optional: true
    belongs_to :parent_transaction, class_name: "TokenLedger::LedgerTransaction", optional: true
    has_many :child_transactions, class_name: "TokenLedger::LedgerTransaction", foreign_key: "parent_transaction_id", dependent: :nullify
    has_many :ledger_entries, class_name: "TokenLedger::LedgerEntry", foreign_key: "transaction_id", dependent: :destroy

    validates :transaction_type, presence: true
    validates :description, presence: true
    validates :external_id, uniqueness: { scope: :external_source }, if: -> { external_source.present? }

    def amount
      ledger_entries.where(entry_type: "debit").sum(:amount)
    end
  end
end
