# frozen_string_literal: true

module TokenLedger
  class Balance
    # Calculate balance from entries (source of truth)
    def self.calculate(account_or_code)
      account = account_or_code.is_a?(String) ?
        LedgerAccount.find_by(code: account_or_code) :
        account_or_code
      return 0 unless account

      entries = LedgerEntry.where(account: account)

      entries.sum do |entry|
        case entry.entry_type
        when "debit" then entry.amount
        when "credit" then -entry.amount
        else 0
        end
      end
    end

    # Reconcile cached balance with calculated balance
    def self.reconcile!(account_or_code)
      account = account_or_code.is_a?(String) ?
        LedgerAccount.find_by(code: account_or_code) :
        account_or_code
      return unless account

      calculated = calculate(account)
      cached = account.current_balance

      if calculated != cached
        account.update_column(:current_balance, calculated)
      end

      calculated
    end

    # Reconcile user's cached balance
    def self.reconcile_user!(user)
      wallet_account = LedgerAccount.find_by(code: "wallet:#{user.id}")
      raise AccountNotFoundError, "Account not found for User ##{user.id}" unless wallet_account

      reconcile!(wallet_account)
      user.update_column(:cached_balance, wallet_account.current_balance)
    end
  end
end
