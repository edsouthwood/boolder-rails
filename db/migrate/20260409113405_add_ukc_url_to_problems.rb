class AddUkcUrlToProblems < ActiveRecord::Migration[8.0]
  def change
    add_column :problems, :ukc_url, :string
  end
end
