class AddBoulderNames < ActiveRecord::Migration[8.1]
  # Boulders get an optional name, and problems an explicit boulder, so a crag list can say
  # which boulder each problem is on before anything is located or photographed.
  def up
    add_column :boulders, :name, :string
    add_index :boulders, "area_id, lower(name)", unique: true, where: "name IS NOT NULL",
      name: "index_boulders_on_area_id_and_lower_name"

    add_reference :problems, :boulder, foreign_key: { on_delete: :nullify }, index: true

    # Problems already sitting on an outline belong to that boulder (same tolerance as
    # Boulder.containing; the first match wins where outlines overlap).
    execute <<~SQL
      UPDATE problems SET boulder_id = sub.boulder_id
      FROM (
        SELECT DISTINCT ON (problems.id) problems.id AS problem_id, boulders.id AS boulder_id
        FROM problems
        JOIN boulders ON boulders.area_id = problems.area_id AND boulders.polygon IS NOT NULL
        WHERE problems.location IS NOT NULL
          AND ST_DWithin(boulders.polygon::geometry, problems.location::geometry, 0.000001)
        ORDER BY problems.id, boulders.id
      ) sub
      WHERE problems.id = sub.problem_id
    SQL
  end

  def down
    remove_reference :problems, :boulder, foreign_key: true, index: true
    remove_index :boulders, name: "index_boulders_on_area_id_and_lower_name"
    remove_column :boulders, :name
  end
end
