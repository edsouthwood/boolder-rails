class AddHiddenToProblems < ActiveRecord::Migration[8.1]
  # Problems an admin has set aside (e.g. low-quality ones from an imported list): kept, but
  # left off the public site and the admin to-do lists until they're unhidden
  def change
    add_column :problems, :hidden, :boolean, default: false, null: false
    add_index :problems, :hidden, where: "hidden"
  end
end
