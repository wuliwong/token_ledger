# frozen_string_literal: true

require "logger"

module TokenLedger
  class Manager
    # Deposit tokens (purchase, bonus)
    def self.deposit(owner:, amount:, description:, external_source: nil, external_id: nil, metadata: {})
      logger.info "TokenLedger::Manager.deposit called - Owner: #{owner&.class&.name}##{owner&.id}, Amount: #{amount}, Source: #{external_source}, ID: #{external_id}"

      return if amount.zero?

      # Determine token source account
      source_code = external_source ? "source:#{external_source}" : "source:other"
      source_name = external_source ? "#{external_source.capitalize} Token Source" : "Other Token Source"

      logger.info "Calling record_transaction for deposit"
      record_transaction(
        type: "deposit",
        description: description,
        owner: owner,
        external_source: external_source,
        external_id: external_id,
        metadata: metadata,
        entries: [
          {
            account_code: "wallet:#{owner.id}",
            account_name: "User #{owner.id} Wallet",
            type: :debit,
            amount: amount
          },
          {
            account_code: source_code,
            account_name: source_name,
            type: :credit,
            amount: amount
          }
        ]
      )
    end

    # Simple spend method - deducts tokens immediately
    # DO NOT use this with external API calls - use reserve/capture/release instead
    def self.spend(owner:, amount:, description:, metadata: {})
      return if amount.zero?

      record_transaction(
        type: "spend",
        description: description,
        owner: owner,
        metadata: metadata,
        entries: [
          {
            account_code: "wallet:#{owner.id}",
            account_name: "User #{owner.id} Wallet",
            type: :credit,
            amount: amount,
            enforce_positive: true # No overdraft
          },
          {
            account_code: "sink:consumed",
            account_name: "Tokens Consumed",
            type: :debit,
            amount: amount
          }
        ]
      )
    end

    # Reserve/Capture/Release pattern for spending with external APIs
    def self.spend_with_api(owner:, amount:, description:, metadata: {}, &block)
      return yield if amount.zero? # Skip ledger for free operations

      # Check available balance (cached)
      raise InsufficientFundsError, "Insufficient tokens" if owner.cached_balance < amount

      reservation_id = nil
      result = nil

      begin
        # Step 1: Reserve tokens (atomic, inside DB transaction)
        reservation_id = reserve(
          owner: owner,
          amount: amount,
          description: "Reserve: #{description}",
          metadata: metadata
        )

        # Step 2: Execute external API (OUTSIDE transaction - cannot rollback)
        result = block.call

        # Step 3: Capture reserved tokens (mark as consumed)
        capture(
          reservation_id: reservation_id,
          description: "Capture: #{description}",
          metadata: metadata
        )

        result
      rescue => e
        # Step 3b: Release reserved tokens on failure
        release(
          reservation_id: reservation_id,
          description: "Release: #{description}",
          metadata: metadata.merge(error: e.message)
        ) if reservation_id

        raise e # Re-raise to maintain error flow
      end
    end

    # Reserve tokens (move from wallet to reserved)
    def self.reserve(owner:, amount:, description:, metadata: {})
      record_transaction(
        type: "reserve",
        description: description,
        owner: owner,
        metadata: metadata,
        entries: [
          {
            account_code: "wallet:#{owner.id}",
            account_name: "User #{owner.id} Wallet",
            type: :credit,
            amount: amount,
            enforce_positive: true # No overdraft
          },
          {
            account_code: "wallet:#{owner.id}:reserved",
            account_name: "User #{owner.id} Reserved",
            type: :debit,
            amount: amount
          }
        ]
      )
    end

    # Capture reserved tokens (mark as consumed)
    def self.capture(reservation_id:, amount: nil, description:, external_source: nil, external_id: nil, metadata: {})
      # Find and verify the reservation transaction
      reservation = LedgerTransaction.find_by(id: reservation_id, transaction_type: "reserve")
      raise ArgumentError, "Reservation transaction #{reservation_id} not found" unless reservation

      owner = reservation.owner
      raise ArgumentError, "Reservation has no owner" unless owner

      # Get the reserved amount from the original transaction
      reserved_entry = reservation.ledger_entries.find_by(entry_type: "debit")
      reserved_amount = reserved_entry.amount

      # Use specified amount or full reserved amount
      capture_amount = amount || reserved_amount

      # Verify we're not capturing more than was reserved
      raise ArgumentError, "Cannot capture #{capture_amount} tokens (only #{reserved_amount} reserved)" if capture_amount > reserved_amount

      record_transaction(
        type: "capture",
        description: description,
        owner: owner,
        parent_transaction_id: reservation_id,
        external_source: external_source,
        external_id: external_id,
        metadata: metadata,
        entries: [
          {
            account_code: "wallet:#{owner.id}:reserved",
            account_name: "User #{owner.id} Reserved",
            type: :credit,
            amount: capture_amount,
            enforce_positive: true
          },
          {
            account_code: "sink:consumed",
            account_name: "Tokens Consumed",
            type: :debit,
            amount: capture_amount
          }
        ]
      )
    end

    # Release reserved tokens (refund to wallet)
    def self.release(reservation_id:, amount: nil, description:, external_source: nil, external_id: nil, metadata: {})
      # Find and verify the reservation transaction
      reservation = LedgerTransaction.find_by(id: reservation_id, transaction_type: "reserve")
      raise ArgumentError, "Reservation transaction #{reservation_id} not found" unless reservation

      owner = reservation.owner
      raise ArgumentError, "Reservation has no owner" unless owner

      # Get the reserved amount from the original transaction
      reserved_entry = reservation.ledger_entries.find_by(entry_type: "debit")
      reserved_amount = reserved_entry.amount

      # Use specified amount or full reserved amount
      release_amount = amount || reserved_amount

      # Verify we're not releasing more than was reserved
      raise ArgumentError, "Cannot release #{release_amount} tokens (only #{reserved_amount} reserved)" if release_amount > reserved_amount

      record_transaction(
        type: "release",
        description: description,
        owner: owner,
        parent_transaction_id: reservation_id,
        external_source: external_source,
        external_id: external_id,
        metadata: metadata,
        entries: [
          {
            account_code: "wallet:#{owner.id}:reserved",
            account_name: "User #{owner.id} Reserved",
            type: :credit,
            amount: release_amount,
            enforce_positive: true
          },
          {
            account_code: "wallet:#{owner.id}",
            account_name: "User #{owner.id} Wallet",
            type: :debit,
            amount: release_amount
          }
        ]
      )
    end

    # Adjust/Reverse a transaction by posting opposite entries
    # Used for corrections, reversals, and manual adjustments
    def self.adjust(owner:, entries:, description:, external_source: nil, external_id: nil, metadata: {})
      record_transaction(
        type: "adjustment",
        description: description,
        owner: owner,
        external_source: external_source,
        external_id: external_id,
        metadata: metadata,
        entries: entries
      )
    end

    # Low-level transaction creation with row-level locking
    def self.record_transaction(type:, description:, entries:, owner: nil, parent_transaction_id: nil, external_source: nil, external_id: nil, metadata: {})
      logger.info "TokenLedger::Manager.record_transaction called - Type: #{type}, Owner: #{owner&.class&.name}##{owner&.id}, External: #{external_source}/#{external_id}"

      ActiveRecord::Base.transaction do
        # Verify entries balance
        debits = entries.select { |e| e[:type] == :debit }.sum { |e| e[:amount] }
        credits = entries.select { |e| e[:type] == :credit }.sum { |e| e[:amount] }

        logger.info "Debits: #{debits}, Credits: #{credits}"

        raise ImbalancedTransactionError, "Debits (#{debits}) != Credits (#{credits})" if debits != credits
        raise ImbalancedTransactionError, "Transaction must have entries" if debits.zero? && credits.zero?

        # Check for duplicate external transaction
        if external_source && external_id
          existing = LedgerTransaction.find_by(external_source: external_source, external_id: external_id)
          if existing
            logger.warn "Duplicate transaction found: #{external_source}/#{external_id}"
            raise DuplicateTransactionError, "Duplicate transaction detected: #{external_source}/#{external_id}"
          end
          logger.info "No duplicate found for #{external_source}/#{external_id}"
        end

        # Create transaction
        logger.info "Creating LedgerTransaction..."
        txn = LedgerTransaction.create!(
          transaction_type: type,
          description: description,
          owner: owner,
          parent_transaction_id: parent_transaction_id,
          external_source: external_source,
          external_id: external_id,
          metadata: metadata
        )
        logger.info "LedgerTransaction created: #{txn.id}"

        # Create entries with row-level locking and balance updates
        entries.each do |entry_data|
          account = Account.find_or_create(
            code: entry_data[:account_code],
            name: entry_data[:account_name]
          )

          # Lock account row for update (prevents race conditions)
          account.lock!

          # Calculate new balance
          balance_delta = case entry_data[:type]
                         when :debit then entry_data[:amount]
                         when :credit then -entry_data[:amount]
                         end

          new_balance = account.current_balance + balance_delta

          # Enforce no overdraft (unless explicitly allowed)
          if entry_data[:enforce_positive] && new_balance < 0
            raise InsufficientFundsError, "Account #{account.code} would go negative (balance: #{account.current_balance}, delta: #{balance_delta})"
          end

          # Update account balance atomically
          account.update_column(:current_balance, new_balance)

          # Create ledger entry
          LedgerEntry.create!(
            account: account,
            ledger_transaction: txn,
            entry_type: entry_data[:type].to_s,
            amount: entry_data[:amount],
            metadata: entry_data[:metadata] || {}
          )
        end

        # Update user cached balance if wallet affected
        if owner && owner.respond_to?(:cached_balance)
          wallet_account = LedgerAccount.find_by(code: "wallet:#{owner.id}")
          if wallet_account
            logger.info "Updating cached_balance for #{owner.class.name}##{owner.id}: #{wallet_account.current_balance}"
            owner.update_column(:cached_balance, wallet_account.current_balance)
            owner.broadcast_balance if owner.respond_to?(:broadcast_balance)
          end
        end

        logger.info "Transaction #{txn.id} completed successfully"
        txn.id
      end
    end

    def self.logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        @logger ||= begin
          fallback_logger = Logger.new($stdout)
          fallback_logger.level = Logger::WARN
          fallback_logger
        end
      end
    end
    private_class_method :logger
  end
end
