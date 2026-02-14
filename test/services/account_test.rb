# frozen_string_literal: true

require "test_helper"

class AccountServiceTest < Minitest::Test
  def setup
    # Delete in order: entries first (child), then transactions, then accounts (parent)
    # This respects the FK constraints with on_delete: :restrict
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
  end

  def test_find_or_create_finds_existing_account
    existing = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_123",
      name: "User 123 Wallet",
      current_balance: 500
    )

    found = TokenLedger::Account.find_or_create(code: "wallet:user_123", name: "User 123")

    assert_equal existing.id, found.id
    assert_equal "wallet:user_123", found.code
    assert_equal "User 123 Wallet", found.name # Original name preserved
    assert_equal 500, found.current_balance # Balance preserved
  end

  def test_find_or_create_creates_new_account
    account = TokenLedger::Account.find_or_create(code: "wallet:user_456", name: "User 456")

    assert account.persisted?
    assert_equal "wallet:user_456", account.code
    assert_equal "User 456", account.name
    assert_equal 0, account.current_balance
  end

  def test_find_or_create_thread_safety
    # Test that concurrent calls to find_or_create for same account code
    # only create one account (no duplicates)
    code = "wallet:concurrent_test"

    threads = 5.times.map do |i|
      Thread.new do
        TokenLedger::Account.find_or_create(code: code, name: "Concurrent #{i}")
      end
    end

    accounts = threads.map(&:value)

    # All threads should get an account
    assert_equal 5, accounts.count

    # All accounts should have the same ID (same account returned)
    unique_ids = accounts.map(&:id).uniq
    assert_equal 1, unique_ids.count, "Expected only one account to be created, got #{unique_ids.count}"

    # Verify only one account exists in database
    assert_equal 1, TokenLedger::LedgerAccount.where(code: code).count
  end

  def test_find_or_create_raises_on_invalid_name
    error = assert_raises(ActiveRecord::RecordInvalid) do
      TokenLedger::Account.find_or_create(code: "wallet:user_1", name: nil)
    end

    assert_match(/Name can't be blank/, error.message)
  end

  def test_find_or_create_raises_on_invalid_code
    error = assert_raises(ActiveRecord::RecordInvalid) do
      TokenLedger::Account.find_or_create(code: nil, name: "User Name")
    end

    assert_match(/Code can't be blank/, error.message)
  end
end
