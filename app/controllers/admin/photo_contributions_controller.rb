# Review queue for boulder photos sent in by visitors. Accepting makes each photo an
# undrawn topo in its area ("Photos to draw"); declining keeps it here, closed.
class Admin::PhotoContributionsController < Admin::BaseController
  def index
    @state = params[:state].presence_in(PhotoContribution::STATES) || (params.key?(:state) ? nil : "pending")
    scope = PhotoContribution.reviewable_by(current_admin_user)
    @pending_count = scope.pending.count

    @photo_contributions = scope.includes(:area, :boulder, :gps_boulder, :topo, photo_attachment: :blob, topo: { photo_attachment: :blob }).
      order(id: :desc)
    @photo_contributions = @photo_contributions.where(state: @state) if @state
    @photo_contributions = @photo_contributions.page(params[:page]).per(60)
  end

  # Accept or decline the ticked photos, or the one whose own button was pressed
  def review
    ids = params[:only_id].present? ? [ params[:only_id] ] : Array(params[:ids]).reject(&:blank?)
    selected = PhotoContribution.reviewable_by(current_admin_user).pending.where(id: ids).includes(:area, photo_attachment: :blob)
    decision = params[:decision].presence_in(%w[accept close])
    return redirect_back_to_queue("Choose accept or decline.") unless decision

    reviewer = current_admin_user&.username
    done = selected.select do |photo_contribution|
      decision == "accept" ? photo_contribution.accept!(reviewed_by: reviewer) : photo_contribution.close!(reviewed_by: reviewer, note: params[:moderator_note])
    end

    email_contributors(done, decision)
    redirect_back_to_queue(notice_for(done, decision))
  end

  private

  def redirect_back_to_queue(notice)
    flash[:notice] = notice
    redirect_to admin_photo_contributions_path(state: params[:return_state].presence)
  end

  def notice_for(done, decision)
    return "Nothing to #{decision == 'accept' ? 'accept' : 'decline'}: those photos have already been reviewed." if done.empty?

    if decision == "accept"
      areas = done.map(&:area).uniq
      links = areas.map do |area|
        helpers.link_to("Photos to draw at #{area.name}", admin_area_topos_path(area_slug: area.slug, undrawn: 1), class: "underline")
      end
      "Accepted #{helpers.pluralize(done.size, 'photo')}. #{helpers.safe_join(links, ' · ')}".html_safe
    else
      "Declined #{helpers.pluralize(done.size, 'photo')}."
    end
  end

  # One email per contributor for this review, however many of their photos it covered
  def email_contributors(done, decision)
    done.select { |pc| pc.contributor_email.present? }.group_by { |pc| pc.contributor_email.downcase }.each_value do |photos|
      PhotoContributionMailer.with(
        contributor_email: photos.first.contributor_email,
        contributor_name: photos.first.contributor_name,
        accepted: decision == "accept" ? photos.size : 0,
        closed: decision == "close" ? photos.size : 0,
        note: decision == "close" ? params[:moderator_note].presence : nil
      ).reviewed_email.deliver_later
    end
  end
end
