# frozen_string_literal: true

require "test_helper"

class LedgerTransactionTest < Minitest::Test
  def setup
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
    User.delete_all
  end

  def test_creates_transaction_with_valid_attributes
    user = User.create!(email: "test@example.com")
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "Initial tokens",
      owner: user
    )

    assert transaction.persisted?
    assert_equal "deposit", transaction.transaction_type
    assert_equal "Initial tokens", transaction.description
    assert_equal user.id, transaction.owner_id
    assert_equal "User", transaction.owner_type
  end

  def test_requires_transaction_type
    transaction = TokenLedger::LedgerTransaction.new(description: "Test")
    refute transaction.valid?
    assert_includes transaction.errors[:transaction_type], "can't be blank"
  end

  def test_allows_nil_owner
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "System transaction"
    )

    assert transaction.persisted?
    assert_nil transaction.owner
  end

  def test_polymorphic_owner_association
    user = User.create!(email: "user@example.com")
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "spend",
      description: "Test transaction",
      owner: user
    )

    assert_equal user, transaction.owner
    assert_equal "User", transaction.owner_type
    assert_equal user.id, transaction.owner_id
  end

  def test_has_many_ledger_entries
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "Test deposit"
    )

    account = TokenLedger::LedgerAccount.create!(
      code: "wallet:user_1",
      name: "User 1",
      current_balance: 0
    )

    entry = TokenLedger::LedgerEntry.create!(
      ledger_transaction: transaction,
      account: account,
      entry_type: "debit",
      amount: 100
    )

    assert_equal 1, transaction.ledger_entries.count
    assert_equal entry.id, transaction.ledger_entries.first.id
  end

  def test_external_id_uniqueness_scoped_to_external_source
    TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "Test",
      external_source: "stripe",
      external_id: "inv_123"
    )

    # Different source, same ID - should be allowed
    duplicate_different_source = TokenLedger::LedgerTransaction.new(
      transaction_type: "deposit",
      description: "Test",
      external_source: "paypal",
      external_id: "inv_123"
    )
    assert duplicate_different_source.valid?

    # Same source, same ID - should fail
    duplicate_same_source = TokenLedger::LedgerTransaction.new(
      transaction_type: "deposit",
      description: "Test",
      external_source: "stripe",
      external_id: "inv_123"
    )
    refute duplicate_same_source.valid?
    assert_includes duplicate_same_source.errors[:external_id], "has already been taken"
  end

  def test_prevents_external_id_without_source
    # external_id without external_source should be rejected by CHECK constraint
    assert_raises(ActiveRecord::CheckViolation) do
      TokenLedger::LedgerTransaction.create!(
        transaction_type: "deposit",
        description: "Test",
        external_id: "inv_123"
      )
    end
  end

  def test_prevents_external_source_without_id
    # external_source without external_id should be rejected by CHECK constraint
    assert_raises(ActiveRecord::CheckViolation) do
      TokenLedger::LedgerTransaction.create!(
        transaction_type: "deposit",
        description: "Test",
        external_source: "stripe"
      )
    end
  end

  def test_stores_metadata_as_json
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "Test",
      metadata: { invoice_id: "inv_123", amount_usd: 10.00 }
    )

    transaction.reload
    assert_equal "inv_123", transaction.metadata["invoice_id"]
    assert_equal 10.00, transaction.metadata["amount_usd"]
  end

  def test_defaults_metadata_to_empty_hash
    transaction = TokenLedger::LedgerTransaction.create!(
      transaction_type: "deposit",
      description: "Test"
    )

    assert_equal({}, transaction.metadata)
  end

  def test_parent_child_transaction_associations
    # Create parent reservation
    parent = TokenLedger::LedgerTransaction.create!(
      transaction_type: "reserve",
      description: "Parent reservation"
    )

    # Create child capture
    capture = TokenLedger::LedgerTransaction.create!(
      transaction_type: "capture",
      description: "Child capture",
      parent_transaction_id: parent.id
    )

    # Create child release
    release = TokenLedger::LedgerTransaction.create!(
      transaction_type: "release",
      description: "Child release",
      parent_transaction_id: parent.id
    )

    # Test parent_transaction association
    assert_equal parent, capture.parent_transaction
    assert_equal parent, release.parent_transaction

    # Test child_transactions association
    assert_equal 2, parent.child_transactions.count
    assert_includes parent.child_transactions, capture
    assert_includes parent.child_transactions, release
  end

  def test_deleting_parent_nullifies_child_parent_transaction_id
    parent = TokenLedger::LedgerTransaction.create!(
      transaction_type: "reserve",
      description: "Parent"
    )

    child = TokenLedger::LedgerTransaction.create!(
      transaction_type: "capture",
      description: "Child",
      parent_transaction_id: parent.id
    )

    assert_equal parent.id, child.parent_transaction_id

    # Delete parent
    parent.destroy

    # Child should still exist but parent_transaction_id should be nullified
    child.reload
    assert_nil child.parent_transaction_id
  end
end
