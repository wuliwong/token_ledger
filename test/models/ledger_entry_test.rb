# frozen_string_literal: true

require "test_helper"

class LedgerEntryTest < Minitest::Test
  def setup
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
  end

  def create_transaction
    TokenLedger::LedgerTransaction.create!(transaction_type: "deposit", description: "Test transaction")
  end

  def create_account
    TokenLedger::LedgerAccount.create!(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: 0
    )
  end

  def test_creates_entry_with_valid_attributes
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )

    assert entry.persisted?
    assert_equal transaction.id, entry.transaction_id
    assert_equal account.id, entry.account_id
    assert_equal "debit", entry.entry_type
    assert_equal 100, entry.amount
  end

  def test_requires_account
    transaction = create_transaction

    entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      entry_type: "debit",
      amount: 100
    )
    refute entry.valid?
    assert_includes entry.errors[:account], "must exist"
  end

  def test_requires_ledger_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.new(
      account: account,
      entry_type: "debit",
      amount: 100
    )
    refute entry.valid?
    assert_includes entry.errors[:ledger_transaction], "must exist"
  end

  def test_requires_entry_type
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      amount: 100
    )
    refute entry.valid?
    assert_includes entry.errors[:entry_type], "can't be blank"
  end

  def test_entry_type_must_be_debit_or_credit
    transaction = create_transaction
    account = create_account

    # Valid entry types
    debit_entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )
    assert debit_entry.valid?

    credit_entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "credit",
      amount: 100
    )
    assert credit_entry.valid?

    # Invalid entry type
    invalid_entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "invalid",
      amount: 100
    )
    refute invalid_entry.valid?
    assert_includes invalid_entry.errors[:entry_type], "is not included in the list"
  end

  def test_requires_amount
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit"
    )
    refute entry.valid?
    assert_includes entry.errors[:amount], "can't be blank"
  end

  def test_amount_must_be_greater_than_zero
    transaction = create_transaction
    account = create_account

    zero_entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 0
    )
    refute zero_entry.valid?
    assert_includes zero_entry.errors[:amount], "must be greater than 0"

    negative_entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: -100
    )
    refute negative_entry.valid?
    assert_includes negative_entry.errors[:amount], "must be greater than 0"
  end

  def test_amount_must_be_integer
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.new(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 10.5
    )
    refute entry.valid?
    assert_includes entry.errors[:amount], "must be an integer"
  end

  def test_stores_metadata_as_json
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100,
      metadata: { category: "signup_bonus", source: "referral" }
    )

    entry.reload
    assert_equal "signup_bonus", entry.metadata["category"]
    assert_equal "referral", entry.metadata["source"]
  end

  def test_defaults_metadata_to_empty_hash
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )

    assert_equal({}, entry.metadata)
  end

  def test_belongs_to_account
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )

    assert_equal account, entry.account
  end

  def test_belongs_to_ledger_transaction
    transaction = create_transaction
    account = create_account

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )

    assert_equal transaction, entry.ledger_transaction
  end
end
