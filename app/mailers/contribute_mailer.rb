class ContributeMailer < ApplicationMailer
  # Staff notification when a new contribution comes in.
  def new_contribution_email
    @contribution = params[:contribution]
    mail(to: self.class.notification_recipients, subject: "New contribution")
  end

  # Contributor-facing: confirmation that we received their submission.
  def acknowledgement_email
    @contribution = params[:contribution]
    return if @contribution.contributor_email.blank?

    mail(to: @contribution.contributor_email, subject: t("contribute_mailer.acknowledgement_email.subject"))
  end

  # Contributor-facing: their contribution was accepted.
  def accepted_email
    @contribution = params[:contribution]
    return if @contribution.contributor_email.blank?

    mail(to: @contribution.contributor_email, subject: t("contribute_mailer.accepted_email.subject"))
  end

  # Contributor-facing: their contribution was declined (optionally with a note).
  def declined_email
    @contribution = params[:contribution]
    return if @contribution.contributor_email.blank?

    mail(to: @contribution.contributor_email, subject: t("contribute_mailer.declined_email.subject"))
  end

  # Recipients for staff notifications. Configured via credentials or the
  # CONTRIBUTION_EMAILS env var (comma-separated), defaulting to the Dartmoor team.
  def self.notification_recipients
    raw = Rails.application.credentials.contribution_emails.presence ||
          ENV["CONTRIBUTION_EMAILS"].presence ||
          "bowda@edsouthwood.com"
    raw.is_a?(Array) ? raw : raw.to_s.split(",").map(&:strip)
  end
end
