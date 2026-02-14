# frozen_string_literal: true

module TokenLedger
  class Account
    def self.find_or_create(code:, name:)
      LedgerAccount.find_or_create_account(code: code, name: name)
    end
  end
end
