class AddDescriptionToProblems < ActiveRecord::Migration[8.0]
  def change
    add_column :problems, :description, :text
  end
end
