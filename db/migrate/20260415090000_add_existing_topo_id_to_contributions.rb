class AddExistingTopoIdToContributions < ActiveRecord::Migration[7.1]
  def change
    add_column :contributions, :existing_topo_id, :bigint
  end
end
