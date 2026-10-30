class ReportsController < ApplicationController
  invisible_captcha only: [ :create ], on_spam: :handle_spam, on_timestamp_spam: :handle_timestamp_spam

  def new
    @contribution = Contribution.new(
      # TODO: make DRY
      contributor_name: session[:contribution_name],
      contributor_email: session[:contribution_email],
      problem: Problem.find_by(id: params[:problem_id])
    )
  end

  # HTML for a plain form post; JSON for report_form_controller.js / offline_reports.js,
  # which send (or later replay) the form via fetch and need to know whether it worked.
  def create
    @contribution = Contribution.new(contribution_params)
    @contribution.problem = Problem.find_by(id: params.dig(:contribution, :problem_id))

    # TODO: make DRY
    session[:contribution_name] = @contribution.contributor_name
    session[:contribution_email] = @contribution.contributor_email

    if @contribution.save
      flash[:notice] = t("views.reports.new.flash_success")

      ContributeMailer.with(contribution: @contribution).new_contribution_email.deliver_later

      respond_to do |format|
        format.html { redirect_to contribute_path }
        format.json { render json: { ok: true }, status: :created }
      end
    else
      respond_to do |format|
        format.html { render "new", status: :unprocessable_entity }
        format.json { render json: { errors: @contribution.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  private

  # invisible_captcha honeypot tripped — silently drop and send the bot home.
  def handle_spam
    respond_to do |format|
      format.html { redirect_to contribute_path }
      format.json { render json: { errors: [ "rejected" ] }, status: :unprocessable_entity }
    end
  end

  # Submitted too soon after the form was loaded (or without loading it at all).
  # HTML keeps invisible_captcha's default behaviour.
  def handle_timestamp_spam
    respond_to do |format|
      format.html do
        flash[:error] = InvisibleCaptcha.timestamp_error_message
        redirect_back(fallback_location: root_path)
      end
      format.json { render json: { errors: [ "too_fast" ] }, status: :unprocessable_entity }
    end
  end

  def contribution_params
    params.require(:contribution).permit(
      :comment, :contributor_name, :contributor_email
    )
  end
end
