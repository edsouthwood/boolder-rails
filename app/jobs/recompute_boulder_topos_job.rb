class RecomputeBoulderToposJob < ApplicationJob
  queue_as :default

  def perform(boulder_ids)
    Boulder.where(id: boulder_ids).order(:id).each(&:recompute_topos!)
  end
end
