# Emails about a suggested new crag: staff when it comes in, the contributor when we get
# it and when it's reviewed. Its photos and problems don't send their own.
class CragSuggestionMailer < ApplicationMailer
  def new_crag_email
    @crag_suggestion = params[:crag_suggestion]
    mail(to: ContributeMailer.notification_recipients, subject: "New crag suggested: #{@crag_suggestion.name}")
  end

  def acknowledgement_email
    @crag_suggestion = params[:crag_suggestion]
    return if @crag_suggestion.contributor_email.blank?

    mail(to: @crag_suggestion.contributor_email, subject: t("crag_suggestion_mailer.acknowledgement_email.subject"))
  end

  def reviewed_email
    @crag_suggestion = params[:crag_suggestion]
    return if @crag_suggestion.contributor_email.blank? || @crag_suggestion.pending?

    mail(to: @crag_suggestion.contributor_email, subject: t("crag_suggestion_mailer.reviewed_email.subject"))
  end
end
