# frozen_string_literal: true

require "test_helper"

class BalanceServiceTest < Minitest::Test
  def setup
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
    User.delete_all
  end

  def create_account(code:, name:, balance: 0)
    TokenLedger::LedgerAccount.create!(
      code: code,
      name: name,
      current_balance: balance
    )
  end

  def create_entry(account:, entry_type:, amount:)
    transaction = TokenLedger::LedgerTransaction.create!(transaction_type: "deposit", description: "Test entry")
    TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: entry_type,
      amount: amount
    )
  end

  def test_calculate_with_no_entries
    account = create_account(code: "wallet:user_1", name: "User 1")

    balance = TokenLedger::Balance.calculate(account)

    assert_equal 0, balance
  end

  def test_calculate_with_only_debits
    account = create_account(code: "wallet:user_1", name: "User 1")
    create_entry(account: account, entry_type: "debit", amount: 100)
    create_entry(account: account, entry_type: "debit", amount: 50)

    balance = TokenLedger::Balance.calculate(account)

    assert_equal 150, balance
  end

  def test_calculate_with_only_credits
    account = create_account(code: "wallet:user_1", name: "User 1")
    create_entry(account: account, entry_type: "credit", amount: 100)
    create_entry(account: account, entry_type: "credit", amount: 50)

    balance = TokenLedger::Balance.calculate(account)

    assert_equal(-150, balance)
  end

  def test_calculate_with_mixed_entries
    account = create_account(code: "wallet:user_1", name: "User 1")
    create_entry(account: account, entry_type: "debit", amount: 200)
    create_entry(account: account, entry_type: "credit", amount: 75)
    create_entry(account: account, entry_type: "debit", amount: 50)
    create_entry(account: account, entry_type: "credit", amount: 25)

    balance = TokenLedger::Balance.calculate(account)

    # (200 + 50) - (75 + 25) = 250 - 100 = 150
    assert_equal 150, balance
  end

  def test_reconcile_updates_cached_balance
    account = create_account(code: "wallet:user_1", name: "User 1", balance: 0)
    create_entry(account: account, entry_type: "debit", amount: 100)
    create_entry(account: account, entry_type: "credit", amount: 30)

    # Cached balance is wrong
    assert_equal 0, account.current_balance

    TokenLedger::Balance.reconcile!(account)

    account.reload
    assert_equal 70, account.current_balance
  end

  def test_reconcile_with_correct_cached_balance
    account = create_account(code: "wallet:user_1", name: "User 1", balance: 100)
    create_entry(account: account, entry_type: "debit", amount: 100)

    TokenLedger::Balance.reconcile!(account)

    account.reload
    assert_equal 100, account.current_balance
  end

  def test_reconcile_with_negative_balance
    account = create_account(code: "wallet:user_1", name: "User 1", balance: 0)
    create_entry(account: account, entry_type: "credit", amount: 50)

    TokenLedger::Balance.reconcile!(account)

    account.reload
    assert_equal(-50, account.current_balance)
  end

  def test_reconcile_user_finds_wallet_account
    user = User.create!(email: "test@example.com", cached_balance: 0)
    account = create_account(code: "wallet:#{user.id}", name: "User #{user.id}", balance: 0)
    create_entry(account: account, entry_type: "debit", amount: 150)

    TokenLedger::Balance.reconcile_user!(user)

    user.reload
    assert_equal 150, user.cached_balance
  end

  def test_reconcile_user_raises_if_account_not_found
    user = User.create!(email: "test@example.com")

    error = assert_raises(TokenLedger::AccountNotFoundError) do
      TokenLedger::Balance.reconcile_user!(user)
    end

    assert_match(/Account not found for User ##{user.id}/, error.message)
  end

  def test_reconcile_user_updates_cached_balance
    user = User.create!(email: "test@example.com", cached_balance: 500)
    account = create_account(code: "wallet:#{user.id}", name: "User #{user.id}", balance: 500)

    # Create entries to support the initial balance
    create_entry(account: account, entry_type: "debit", amount: 500)

    # Spend some tokens
    create_entry(account: account, entry_type: "credit", amount: 200)

    # Manually break the cached balance (simulate out of sync state)
    account.update_column(:current_balance, 999)
    user.update_column(:cached_balance, 999)

    TokenLedger::Balance.reconcile_user!(user)

    user.reload
    account.reload
    assert_equal 300, user.cached_balance
    assert_equal 300, account.current_balance
  end
end
