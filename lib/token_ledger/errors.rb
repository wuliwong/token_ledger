# frozen_string_literal: true

module TokenLedger
  class Error < StandardError; end
  class InsufficientFundsError < Error; end
  class ImbalancedTransactionError < Error; end
  class DuplicateTransactionError < Error; end
  class AccountNotFoundError < Error; end
end
