# Anonymous daily visit totals: one row per day and page (home, an area, a problem, the
# map), with nothing about who visited. See PageView and CountsPageViews.
class CreatePageViews < ActiveRecord::Migration[8.1]
  def change
    create_table :page_views do |t|
      t.date :day, null: false
      t.string :kind, null: false
      t.bigint :area_id, null: false, default: 0 # 0 = none (home page, or the map with no area)
      t.bigint :problem_id, null: false, default: 0
      t.integer :views, null: false, default: 0
    end
    add_index :page_views, [ :day, :kind, :area_id, :problem_id ], unique: true, name: "index_page_views_on_day_and_page"
    add_index :page_views, [ :area_id, :day ]
  end
end
