# frozen_string_literal: true

module TokenLedger
  class LedgerAccount < ActiveRecord::Base
    self.table_name = "ledger_accounts"

    has_many :ledger_entries, class_name: "TokenLedger::LedgerEntry", foreign_key: "account_id", dependent: :restrict_with_error

    validates :code, presence: true, uniqueness: true
    validates :name, presence: true
    validates :current_balance, presence: true, numericality: { only_integer: true }

    def self.find_or_create_account(code:, name:)
      find_or_create_by!(code: code) do |account|
        account.name = name
        account.current_balance = 0
        account.metadata = {}
      end
    end
  end
end
