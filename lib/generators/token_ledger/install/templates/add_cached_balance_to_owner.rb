# frozen_string_literal: true

class AddCachedBalanceTo<%= owner_class_name.pluralize %> < ActiveRecord::Migration[7.0]
  def change
    add_column :<%= owner_table_name %>, :cached_balance, :bigint, default: 0, null: false
    add_index :<%= owner_table_name %>, :cached_balance
  end
end
