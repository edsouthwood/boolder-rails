class AddStateIndexToContributions < ActiveRecord::Migration[8.0]
  def change
    add_index :contributions, :state
  end
end
