# frozen_string_literal: true

require "test_helper"

class ManagerServiceTest < Minitest::Test
  def setup
    TokenLedger::LedgerEntry.delete_all
    TokenLedger::LedgerTransaction.delete_all
    TokenLedger::LedgerAccount.delete_all
    User.delete_all
  end

  def create_user_with_balance(balance)
    user = User.create!(email: "test@example.com", cached_balance: balance)
    wallet = TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}",
      name: "User #{user.id} Wallet",
      current_balance: balance
    )
    [user, wallet]
  end

  def create_system_account(code, name)
    TokenLedger::LedgerAccount.create!(
      code: code,
      name: name,
      current_balance: 0
    )
  end

  # ========================================
  # Deposit Tests
  # ========================================

  def test_deposit_adds_tokens_to_wallet
    user, wallet = create_user_with_balance(0)
    revenue = create_system_account("source:other", "Other Token Source")

    TokenLedger::Manager.deposit(
      owner: user,
      amount: 100,
      description: "Token purchase"
    )

    wallet.reload
    user.reload
    revenue.reload

    assert_equal 100, wallet.current_balance
    assert_equal 100, user.cached_balance
    assert_equal(-100, revenue.current_balance) # Source account credited
  end

  def test_deposit_creates_transaction_with_metadata
    user, _wallet = create_user_with_balance(0)
    create_system_account("source:stripe", "Stripe Token Source")

    TokenLedger::Manager.deposit(
      owner: user,
      amount: 100,
      description: "Subscription renewal",
      external_source: "stripe",
      external_id: "inv_123",
      metadata: { plan: "pro" }
    )

    txn = TokenLedger::LedgerTransaction.last
    assert_equal "deposit", txn.transaction_type
    assert_equal "Subscription renewal", txn.description
    assert_equal "stripe", txn.external_source
    assert_equal "inv_123", txn.external_id
    assert_equal "pro", txn.metadata["plan"]
  end

  def test_deposit_prevents_duplicate_with_idempotency_key
    user, wallet = create_user_with_balance(0)
    create_system_account("source:stripe", "Stripe Token Source")

    # First deposit
    TokenLedger::Manager.deposit(
      owner: user,
      amount: 100,
      description: "Payment",
      external_source: "stripe",
      external_id: "inv_123"
    )

    # Duplicate deposit with same idempotency key
    error = assert_raises(TokenLedger::DuplicateTransactionError) do
      TokenLedger::Manager.deposit(
        owner: user,
        amount: 100,
        description: "Payment",
        external_source: "stripe",
        external_id: "inv_123"
      )
    end

    assert_match(/Duplicate transaction detected/, error.message)

    wallet.reload
    user.reload
    assert_equal 100, wallet.current_balance # Only credited once
    assert_equal 100, user.cached_balance
  end

  def test_deposit_allows_same_external_id_with_different_source
    user, wallet = create_user_with_balance(0)
    create_system_account("source:stripe", "Stripe Token Source")
    create_system_account("source:paypal", "PayPal Token Source")

    TokenLedger::Manager.deposit(
      owner: user,
      amount: 100,
      description: "Payment",
      external_source: "stripe",
      external_id: "inv_123"
    )

    TokenLedger::Manager.deposit(
      owner: user,
      amount: 50,
      description: "Payment",
      external_source: "paypal",
      external_id: "inv_123"
    )

    wallet.reload
    assert_equal 150, wallet.current_balance
  end

  def test_deposit_creates_balanced_entries
    user, _wallet = create_user_with_balance(0)
    create_system_account("source:other", "Other Token Source")

    TokenLedger::Manager.deposit(owner: user, amount: 100, description: "Test")

    txn = TokenLedger::LedgerTransaction.last
    entries = txn.ledger_entries.to_a

    assert_equal 2, entries.count

    debit = entries.find { |e| e.entry_type == "debit" }
    credit = entries.find { |e| e.entry_type == "credit" }

    assert_equal 100, debit.amount
    assert_equal 100, credit.amount
    assert_equal "wallet:#{user.id}", debit.account.code
    assert_equal "source:other", credit.account.code
  end

  # ========================================
  # Spend Tests
  # ========================================

  def test_spend_deducts_tokens_from_wallet
    user, wallet = create_user_with_balance(100)
    create_system_account("sink:consumed", "Tokens Consumed")

    TokenLedger::Manager.spend(
      owner: user,
      amount: 30,
      description: "Image generation"
    )

    wallet.reload
    user.reload

    assert_equal 70, wallet.current_balance
    assert_equal 70, user.cached_balance
  end

  def test_spend_raises_on_insufficient_funds
    user, wallet = create_user_with_balance(50)
    create_system_account("sink:consumed", "Tokens Consumed")

    error = assert_raises(TokenLedger::InsufficientFundsError) do
      TokenLedger::Manager.spend(owner: user, amount: 100, description: "Test")
    end

    assert_match(/would go negative/, error.message)

    wallet.reload
    user.reload
    assert_equal 50, wallet.current_balance # Balance unchanged
    assert_equal 50, user.cached_balance
  end

  def test_spend_deducts_without_rollback
    user, wallet = create_user_with_balance(100)
    create_system_account("sink:consumed", "Tokens Consumed")

    TokenLedger::Manager.spend(owner: user, amount: 10, description: "Test")

    wallet.reload
    user.reload
    assert_equal 90, wallet.current_balance
    assert_equal 90, user.cached_balance
    assert_equal 1, TokenLedger::LedgerTransaction.count
  end

  def test_spend_creates_balanced_entries
    user, _wallet = create_user_with_balance(100)
    create_system_account("sink:consumed", "Tokens Consumed")

    TokenLedger::Manager.spend(owner: user, amount: 25, description: "Test")

    txn = TokenLedger::LedgerTransaction.last
    entries = txn.ledger_entries.to_a

    assert_equal 2, entries.count

    credit = entries.find { |e| e.entry_type == "credit" }
    debit = entries.find { |e| e.entry_type == "debit" }

    assert_equal 25, credit.amount
    assert_equal 25, debit.amount
    assert_equal "wallet:#{user.id}", credit.account.code
    assert_equal "sink:consumed", debit.account.code
  end

  # ========================================
  # Reserve/Capture/Release Tests
  # ========================================

  def test_reserve_moves_tokens_to_reserved_account
    user, wallet = create_user_with_balance(100)
    reserved = TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )

    reservation_id = TokenLedger::Manager.reserve(
      owner: user,
      amount: 30,
      description: "Reserve for API call"
    )

    wallet.reload
    reserved.reload
    user.reload

    assert_kind_of Integer, reservation_id
    assert_equal 70, wallet.current_balance
    assert_equal 30, reserved.current_balance
    assert_equal 70, user.cached_balance # cached_balance reflects available tokens
  end

  def test_reserve_raises_on_insufficient_funds
    user, wallet = create_user_with_balance(20)

    error = assert_raises(TokenLedger::InsufficientFundsError) do
      TokenLedger::Manager.reserve(owner: user, amount: 50, description: "Test")
    end

    assert_match(/would go negative/, error.message)

    wallet.reload
    assert_equal 20, wallet.current_balance
  end

  def test_capture_converts_reservation_to_expense
    user, wallet = create_user_with_balance(100)
    reserved = TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )
    create_system_account("sink:consumed", "Tokens Consumed")

    reservation_id = TokenLedger::Manager.reserve(owner: user, amount: 30, description: "Reserve")

    TokenLedger::Manager.capture(
      reservation_id: reservation_id,
      description: "Image generation completed"
    )

    wallet.reload
    reserved.reload
    user.reload

    assert_equal 70, wallet.current_balance # Still 70 (was already deducted)
    assert_equal 0, reserved.current_balance # Reservation cleared
    assert_equal 70, user.cached_balance
  end

  def test_release_returns_tokens_to_wallet
    user, wallet = create_user_with_balance(100)
    reserved = TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )

    reservation_id = TokenLedger::Manager.reserve(owner: user, amount: 30, description: "Reserve")

    TokenLedger::Manager.release(
      reservation_id: reservation_id,
      description: "API call failed, refund"
    )

    wallet.reload
    reserved.reload
    user.reload

    assert_equal 100, wallet.current_balance # Refunded
    assert_equal 0, reserved.current_balance # Reservation cleared
    assert_equal 100, user.cached_balance
  end

  def test_reserve_capture_release_flow
    user, wallet = create_user_with_balance(100)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )
    create_system_account("sink:consumed", "Tokens Consumed")

    # Reserve
    reservation_id = TokenLedger::Manager.reserve(owner: user, amount: 40, description: "Reserve")
    wallet.reload
    user.reload
    assert_equal 60, wallet.current_balance
    assert_equal 60, user.cached_balance

    # Capture half
    TokenLedger::Manager.capture(
      reservation_id: reservation_id,
      amount: 25,
      description: "Partial usage"
    )
    wallet.reload
    user.reload
    assert_equal 60, wallet.current_balance
    assert_equal 60, user.cached_balance

    # Release the rest
    TokenLedger::Manager.release(
      reservation_id: reservation_id,
      amount: 15,
      description: "Refund unused"
    )
    wallet.reload
    user.reload
    assert_equal 75, wallet.current_balance # 60 + 15 refunded
    assert_equal 75, user.cached_balance
  end

  # ========================================
  # Concurrency Tests
  # ========================================

  def test_concurrent_spends_prevent_overdraft
    user, wallet = create_user_with_balance(100)
    create_system_account("sink:consumed", "Tokens Consumed")

    # Use threads to attempt concurrent spends
    # Reduced to 2 threads to work with SQLite's concurrency limits
    threads = 2.times.map do |i|
      Thread.new do
        begin
          TokenLedger::Manager.spend(
            owner: user,
            amount: 60,
            description: "Concurrent spend #{i}"
          )
          :success
        rescue TokenLedger::InsufficientFundsError
          :insufficient_funds
        rescue ActiveRecord::StatementTimeout
          # SQLite may timeout - this proves locking works
          :timeout
        end
      end
    end

    results = threads.map(&:value)

    # One spend should succeed, one should fail
    successes = results.count { |r| r == :success }
    failures = results.count { |r| r == :insufficient_funds || r == :timeout }

    assert_equal 1, successes, "Exactly one concurrent spend should succeed"
    assert_equal 1, failures, "Exactly one concurrent spend should fail"

    wallet.reload
    user.reload

    # Final balance should be 40 (100 - 60)
    assert_equal 40, wallet.current_balance
    assert_equal wallet.current_balance, user.cached_balance
  end

  def test_concurrent_deposits_all_succeed
    user, wallet = create_user_with_balance(0)
    create_system_account("source:stripe", "Stripe Token Source")

    # Use threads to deposit concurrently
    threads = 5.times.map do |i|
      Thread.new do
        TokenLedger::Manager.deposit(
          owner: user,
          amount: 20,
          description: "Concurrent deposit #{i}",
          external_source: "stripe",
          external_id: "dep_#{i}"
        )
      end
    end

    threads.each(&:join)

    wallet.reload
    user.reload

    # All deposits should succeed
    assert_equal 100, wallet.current_balance
    assert_equal 100, user.cached_balance
    assert_equal 5, TokenLedger::LedgerTransaction.where(transaction_type: "deposit").count
  end

  def test_reserve_capture_prevents_double_spend
    user, _wallet = create_user_with_balance(100)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )
    create_system_account("sink:consumed", "Tokens Consumed")

    # Reserve some tokens
    TokenLedger::Manager.reserve(owner: user, amount: 60, description: "Reserve")

    # Try to spend the remaining available balance concurrently
    threads = 2.times.map do |i|
      Thread.new do
        begin
          TokenLedger::Manager.spend(
            owner: user,
            amount: 30,
            description: "Concurrent spend #{i}"
          )
          :success
        rescue TokenLedger::InsufficientFundsError
          :insufficient_funds
        rescue ActiveRecord::StatementTimeout
          # SQLite may timeout - this proves locking works
          :timeout
        end
      end
    end

    results = threads.map(&:value)

    # Only one should succeed (40 available / 30 requested = 1 max)
    successes = results.count { |r| r == :success }
    assert_equal 1, successes, "Exactly one concurrent spend should succeed with reserved tokens"
  end

  def test_concurrent_reservations_capture_correct_ones
    user, wallet = create_user_with_balance(200)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )
    create_system_account("sink:consumed", "Tokens Consumed")

    # Create two concurrent reservations
    reservation_1 = TokenLedger::Manager.reserve(owner: user, amount: 50, description: "Reservation 1")
    reservation_2 = TokenLedger::Manager.reserve(owner: user, amount: 75, description: "Reservation 2")

    # Verify both reservations succeeded
    wallet.reload
    assert_equal 75, wallet.current_balance # 200 - 50 - 75

    # Capture specific reservations in threads to simulate concurrent jobs
    threads = [
      Thread.new do
        TokenLedger::Manager.capture(
          reservation_id: reservation_1,
          description: "Capture reservation 1"
        )
      end,
      Thread.new do
        TokenLedger::Manager.release(
          reservation_id: reservation_2,
          description: "Release reservation 2"
        )
      end
    ]

    threads.each(&:join)

    wallet.reload
    user.reload

    # Reservation 1 was captured (consumed), reservation 2 was released (refunded)
    # Final balance: 75 + 75 (released) = 150
    assert_equal 150, wallet.current_balance
    assert_equal 150, user.cached_balance

    # Verify transaction history
    capture_txn = TokenLedger::LedgerTransaction.find_by(transaction_type: "capture")
    release_txn = TokenLedger::LedgerTransaction.find_by(transaction_type: "release")

    refute_nil capture_txn, "Capture transaction should exist"
    refute_nil release_txn, "Release transaction should exist"
    assert_equal reservation_1, capture_txn.parent_transaction_id
    assert_equal reservation_2, release_txn.parent_transaction_id
  end

  # ========================================
  # Balance Validation Tests
  # ========================================

  def test_record_transaction_validates_balanced_entries
    user, wallet = create_user_with_balance(100)
    expense = create_system_account("sink:consumed", "Tokens Consumed")

    error = assert_raises(TokenLedger::ImbalancedTransactionError) do
      TokenLedger::Manager.send(:record_transaction,
        type: "test",
        description: "Imbalanced test",
        owner: user,
        entries: [
          { account_code: expense.code, account_name: "Expense", type: :debit, amount: 100 },
          { account_code: wallet.code, account_name: "Wallet", type: :credit, amount: 50 }
        ]
      )
    end

    assert_match(/Debits.*Credits/, error.message)
  end

  def test_record_transaction_with_empty_entries
    user, _wallet = create_user_with_balance(100)

    error = assert_raises(TokenLedger::ImbalancedTransactionError) do
      TokenLedger::Manager.send(:record_transaction,
        type: "test",
        description: "Empty test",
        owner: user,
        entries: []
      )
    end

    assert_match(/Transaction must have entries/, error.message)
  end

  # ========================================
  # Idempotency Tests
  # ========================================

  def test_capture_prevents_duplicate_with_idempotency_key
    user, wallet = create_user_with_balance(100)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )
    create_system_account("sink:consumed", "Tokens Consumed")

    reservation_id = TokenLedger::Manager.reserve(owner: user, amount: 50, description: "Reserve")

    # First capture
    TokenLedger::Manager.capture(
      reservation_id: reservation_id,
      description: "Job completed",
      external_source: "job_runner",
      external_id: "job_123:capture"
    )

    # Duplicate capture with same idempotency key
    error = assert_raises(TokenLedger::DuplicateTransactionError) do
      TokenLedger::Manager.capture(
        reservation_id: reservation_id,
        description: "Job completed",
        external_source: "job_runner",
        external_id: "job_123:capture"
      )
    end

    assert_match(/Duplicate transaction detected/, error.message)

    wallet.reload
    user.reload
    assert_equal 50, wallet.current_balance # Only captured once
  end

  def test_release_prevents_duplicate_with_idempotency_key
    user, wallet = create_user_with_balance(100)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )

    reservation_id = TokenLedger::Manager.reserve(owner: user, amount: 50, description: "Reserve")

    # First release
    TokenLedger::Manager.release(
      reservation_id: reservation_id,
      description: "Job failed",
      external_source: "job_runner",
      external_id: "job_123:release"
    )

    # Duplicate release with same idempotency key
    error = assert_raises(TokenLedger::DuplicateTransactionError) do
      TokenLedger::Manager.release(
        reservation_id: reservation_id,
        description: "Job failed",
        external_source: "job_runner",
        external_id: "job_123:release"
      )
    end

    assert_match(/Duplicate transaction detected/, error.message)

    wallet.reload
    user.reload
    assert_equal 100, wallet.current_balance # Only released once
  end

  # ========================================
  # Metadata Tests
  # ========================================

  def test_spend_stores_metadata
    user, _wallet = create_user_with_balance(100)
    create_system_account("sink:consumed", "Tokens Consumed")

    TokenLedger::Manager.spend(
      owner: user,
      amount: 10,
      description: "Image generation",
      metadata: { adapter: "flux", resolution: "1024x1024" }
    )

    txn = TokenLedger::LedgerTransaction.last
    assert_equal "flux", txn.metadata["adapter"]
    assert_equal "1024x1024", txn.metadata["resolution"]
  end

  def test_reserve_stores_metadata
    user, _wallet = create_user_with_balance(100)
    TokenLedger::LedgerAccount.create!(
      code: "wallet:#{user.id}:reserved",
      name: "User #{user.id} Reserved",
      current_balance: 0
    )

    reservation_id = TokenLedger::Manager.reserve(
      owner: user,
      amount: 30,
      description: "Reserve",
      metadata: { job_id: "job_123" }
    )

    txn = TokenLedger::LedgerTransaction.find(reservation_id)
    assert_equal "job_123", txn.metadata["job_id"]
  end
end
