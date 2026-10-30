class AddStartHoldsToLines < ActiveRecord::Migration[8.1]
  def change
    add_column :lines, :start_holds, :json
  end
end
