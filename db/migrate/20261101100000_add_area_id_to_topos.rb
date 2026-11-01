class AddAreaIdToTopos < ActiveRecord::Migration[8.1]
  # Lets a photo belong to an area before any lines are drawn on it (photo inbox)
  def up
    add_reference :topos, :area, foreign_key: true, index: true

    execute <<~SQL
      UPDATE topos SET area_id = sub.area_id
      FROM (
        SELECT DISTINCT ON (lines.topo_id) lines.topo_id, problems.area_id
        FROM lines JOIN problems ON problems.id = lines.problem_id
        ORDER BY lines.topo_id, lines.created_at
      ) sub
      WHERE topos.id = sub.topo_id
    SQL
  end

  def down
    remove_reference :topos, :area, foreign_key: true, index: true
  end
end
