class AddStartHoldsToContributions < ActiveRecord::Migration[8.1]
  def change
    add_column :contributions, :start_holds, :json
  end
end
