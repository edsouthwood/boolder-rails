# Counts a visit to a public page in PageView's anonymous daily totals.
#
# Only real visits count: a page the browser navigated to, or a Turbo link click.
# Offline downloads (plain fetch), admins, bots and errors don't. Turbo's hover prefetch
# is switched off in the public layouts (turbo-prefetch meta): a prefetched page is shown
# on click without another request, so those visits would otherwise be lost. Nothing about the visitor is stored. Counting never breaks the page.
module CountsPageViews
  extend ActiveSupport::Concern

  BOT_AGENT = /bot|crawl|spider|slurp|archiver|scrape|facebookexternalhit|embedly|preview|monitor|uptime|curl|wget|python|ruby|java\/|go-http|okhttp|headless|lighthouse|pingdom|httpclient/i

  class_methods do
    # count_page_views :problem, only: :show do { area: @problem.area, problem: @problem } end
    def count_page_views(kind, only:, &details)
      after_action(only: only) do
        attributes = details ? instance_exec(&details) : {}
        count_page_view(kind, **attributes)
      end
    end
  end

  private

  def count_page_view(kind, area: nil, problem: nil)
    return unless countable_visit?

    PageView.record(kind, area_id: area&.id, problem_id: problem&.id)
  rescue StandardError => e
    Rails.logger.warn("[page views] not counted: #{e.class}: #{e.message}")
  end

  def countable_visit?
    return false unless request.get? && response.status == 200 && request.format.html?
    return false if admin_session?
    return false if request.headers["Turbo-Frame"].present?

    purpose = [ request.headers["Sec-Purpose"], request.headers["X-Sec-Purpose"], request.headers["Purpose"] ].join(" ")
    return false if purpose.include?("prefetch")

    navigation = request.headers["Sec-Fetch-Mode"] == "navigate" || request.headers["X-Turbo-Request-Id"].present?
    agent = request.user_agent.to_s
    navigation && agent.present? && !agent.match?(BOT_AGENT)
  end
end
