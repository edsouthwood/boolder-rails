# Emails about boulder photos. Uploads come one request per photo, so each upload
# session (batch) is emailed about once, and each review action once per contributor.
class PhotoContributionMailer < ApplicationMailer
  # Staff: someone has started sending photos in
  def new_photos_email
    @photo_contribution = params[:photo_contribution]
    mail(to: ContributeMailer.notification_recipients, subject: "New boulder photos at #{@photo_contribution.area.name}")
  end

  # Contributor: we got them
  def acknowledgement_email
    @photo_contribution = params[:photo_contribution]
    return if @photo_contribution.contributor_email.blank?

    mail(to: @photo_contribution.contributor_email, subject: t("photo_contribution_mailer.acknowledgement_email.subject"))
  end

  # Contributor: how a review went. Counts, not names: one email for however many were reviewed.
  def reviewed_email
    @name = params[:contributor_name]
    @accepted = params[:accepted].to_i
    @closed = params[:closed].to_i
    @note = params[:note]
    return if params[:contributor_email].blank? || (@accepted + @closed).zero?

    mail(to: params[:contributor_email], subject: t("photo_contribution_mailer.reviewed_email.subject"))
  end
end
