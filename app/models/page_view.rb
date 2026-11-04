# Anonymous daily visit totals for the admin stats page. Each row is a count for one
# day and page; no IP address, cookie, user agent or visitor identifier is stored.
class PageView < ApplicationRecord
  KINDS = %w[home area problem map].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :between, ->(range) { where(day: range) }

  # Adds one view to today's total for the page
  def self.record(kind, area_id: nil, problem_id: nil)
    raise ArgumentError, "unknown page kind #{kind}" unless KINDS.include?(kind.to_s)

    upsert({ day: Date.current, kind: kind.to_s, area_id: area_id || 0, problem_id: problem_id || 0, views: 1 },
      unique_by: :index_page_views_on_day_and_page,
      on_duplicate: Arel.sql("views = page_views.views + 1"),
      record_timestamps: false)
  end
end
