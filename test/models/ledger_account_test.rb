# frozen_string_literal: true

require "test_helper"

class LedgerAccountTest < Minitest::Test
  def setup
    # Delete in order: entries first (child), then transactions, then accounts (parent)
    # This respects the FK constraints with on_delete: :restrict
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
  end

  def test_creates_account_with_valid_attributes
    account = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_123",
      name: "User 123 Wallet",
      current_balance: 0
    )

    assert account.persisted?
    assert_equal "wallet:user_123", account.code
    assert_equal "User 123 Wallet", account.name
    assert_equal 0, account.current_balance
  end

  def test_requires_code
    account = TokenLedger::LedgerAccount.new(name: "Test Account")
    refute account.valid?
    assert_includes account.errors[:code], "can't be blank"
  end

  def test_requires_unique_code
    TokenLedger::LedgerAccount.create!(code: "wallet:user_1", name: "User 1")

    duplicate = TokenLedger::LedgerAccount.new(code: "wallet:user_1", name: "User 1 Duplicate")
    refute duplicate.valid?
    assert_includes duplicate.errors[:code], "has already been taken"
  end

  def test_requires_name
    account = TokenLedger::LedgerAccount.new(code: "wallet:user_1")
    refute account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  def test_requires_current_balance
    account = TokenLedger::LedgerAccount.new(code: "wallet:user_1", name: "User 1", current_balance: nil)
    refute account.valid?
    assert_includes account.errors[:current_balance], "can't be blank"
  end

  def test_current_balance_must_be_integer
    account = TokenLedger::LedgerAccount.new(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: 10.5
    )
    refute account.valid?
    assert_includes account.errors[:current_balance], "must be an integer"
  end

  def test_allows_negative_balance
    account = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: -100
    )
    assert account.persisted?
    assert_equal(-100, account.current_balance)
  end

  def test_find_or_create_account_creates_new_account
    account = TokenLedger::LedgerAccount.find_or_create_account(
      code: "wallet:user_456",
      name: "User 456 Wallet"
    )

    assert account.persisted?
    assert_equal "wallet:user_456", account.code
    assert_equal "User 456 Wallet", account.name
    assert_equal 0, account.current_balance
  end

  def test_find_or_create_account_finds_existing_account
    existing = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_789",
      name: "User 789 Wallet",
      current_balance: 500
    )

    found = TokenLedger::LedgerAccount.find_or_create_account(
      code: "wallet:user_789",
      name: "Different Name"
    )

    assert_equal existing.id, found.id
    assert_equal "User 789 Wallet", found.name # Name doesn't change
    assert_equal 500, found.current_balance # Balance doesn't change
  end

  def test_stores_metadata_as_json
    account = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: 0,
      metadata: { user_tier: "premium", signup_date: "2025-01-01" }
    )

    account.reload
    assert_equal "premium", account.metadata["user_tier"]
    assert_equal "2025-01-01", account.metadata["signup_date"]
  end

  def test_defaults_metadata_to_empty_hash
    account = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: 0
    )

    assert_equal({}, account.metadata)
  end
end
