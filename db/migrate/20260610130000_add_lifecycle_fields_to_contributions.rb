class AddLifecycleFieldsToContributions < ActiveRecord::Migration[8.0]
  def change
    add_column :contributions, :accepted_at, :datetime
    add_column :contributions, :closed_at, :datetime
    add_column :contributions, :reviewed_by, :string
  end
end
