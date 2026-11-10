# frozen_string_literal: true

class Api::V1::DashboardController < Api::V1::BaseController
  require_permissions({
    customer: 'dashboard.read',
    daily_summary: 'dashboard.read'
  })

  def customer
    dashboard_data = Dashboard::CustomerDashboardService.new(
      params: dashboard_params
    ).call

    success_response(
      data: dashboard_data,
      message: 'Customer dashboard data retrieved successfully'
    )
  end

  def daily_summary
    return error_response(ApiErrorCodes::OPERATION_NOT_ALLOWED, 'A user context is required', status: :forbidden) if Current.user.blank?

    summary = Dashboard::DailySummaryService.new(
      user: Current.user,
      pipelines: policy_scope(Pipeline),
      date: params[:date],
      timezone: params[:timezone]
    ).call

    success_response(data: summary, message: 'Daily summary retrieved successfully')
  rescue ArgumentError => e
    error_response(ApiErrorCodes::INVALID_PARAMETER, e.message, status: :unprocessable_entity)
  end

  private

  def dashboard_params
    params.permit(:pipeline_id, :team_id, :inbox_id, :user_id, :since, :until)
  end
end
