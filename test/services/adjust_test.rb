# frozen_string_literal: true

require "test_helper"

class AdjustServiceTest < Minitest::Test
  def setup
    # Delete in order: entries first (child), then transactions, then accounts (parent)
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
    @user = User.create!(email: "test@example.com", cached_balance: 0)
  end

  def test_adjust_creates_adjustment_transaction
    # First, deposit some tokens
    original_txn_id = TokenLedger::Manager.deposit(
      owner: @user,
      amount: 100,
      description: "Original deposit"
    )

    @user.reload
    assert_equal 100, @user.cached_balance

    # Now reverse it using adjust
    original = TokenLedger::LedgerTransaction.find(original_txn_id)

    TokenLedger::Manager.adjust(
      owner: @user,
      description: "Reversal of transaction ##{original.id}",
      entries: original.ledger_entries.map { |entry|
        {
          account_code: entry.account.code,
          account_name: entry.account.name,
          type: entry.entry_type == "debit" ? :credit : :debit,
          amount: entry.amount
        }
      }
    )

    @user.reload
    assert_equal 0, @user.cached_balance, "Balance should be zero after reversal"

    # Verify the adjustment transaction was created
    adjustment = TokenLedger::LedgerTransaction.find_by(transaction_type: "adjustment")
    refute_nil adjustment
    assert_equal "Reversal of transaction ##{original.id}", adjustment.description
  end

  def test_adjust_with_idempotency
    # Create an adjustment with external_id
    TokenLedger::Manager.adjust(
      owner: @user,
      description: "Manual adjustment",
      external_source: "admin",
      external_id: "adj_123",
      entries: [
        { account_code: "wallet:#{@user.id}", account_name: "User Wallet", type: :debit, amount: 50 },
        { account_code: "source:admin", account_name: "Admin Source", type: :credit, amount: 50 }
      ]
    )

    @user.reload
    assert_equal 50, @user.cached_balance

    # Try to create the same adjustment again
    error = assert_raises(TokenLedger::DuplicateTransactionError) do
      TokenLedger::Manager.adjust(
        owner: @user,
        description: "Manual adjustment (duplicate)",
        external_source: "admin",
        external_id: "adj_123",
        entries: [
          { account_code: "wallet:#{@user.id}", account_name: "User Wallet", type: :debit, amount: 50 },
          { account_code: "source:admin", account_name: "Admin Source", type: :credit, amount: 50 }
        ]
      )
    end

    assert_match(/Duplicate transaction detected: admin\/adj_123/, error.message)
    @user.reload
    assert_equal 50, @user.cached_balance, "Balance should not change on duplicate"
  end

  def test_adjust_requires_balanced_entries
    error = assert_raises(TokenLedger::ImbalancedTransactionError) do
      TokenLedger::Manager.adjust(
        owner: @user,
        description: "Unbalanced adjustment",
        entries: [
          { account_code: "wallet:#{@user.id}", account_name: "User Wallet", type: :debit, amount: 100 },
          { account_code: "source:admin", account_name: "Admin Source", type: :credit, amount: 50 }
        ]
      )
    end

    assert_match(/Debits .* != Credits/, error.message)
  end

  def test_adjust_can_reverse_spend_transaction
    # Deposit 100 tokens
    TokenLedger::Manager.deposit(owner: @user, amount: 100, description: "Initial deposit")
    @user.reload
    assert_equal 100, @user.cached_balance

    # Spend 30 tokens
    spend_txn_id = TokenLedger::Manager.spend(owner: @user, amount: 30, description: "Service consumed")
    @user.reload
    assert_equal 70, @user.cached_balance

    # Reverse the spend using adjust
    spend_txn = TokenLedger::LedgerTransaction.find(spend_txn_id)
    TokenLedger::Manager.adjust(
      owner: @user,
      description: "Refund for transaction ##{spend_txn.id}",
      entries: spend_txn.ledger_entries.map { |entry|
        {
          account_code: entry.account.code,
          account_name: entry.account.name,
          type: entry.entry_type == "debit" ? :credit : :debit,
          amount: entry.amount
        }
      }
    )

    @user.reload
    assert_equal 100, @user.cached_balance, "Balance should be back to 100 after refund"
  end
end
