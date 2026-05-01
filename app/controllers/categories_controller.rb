class CategoriesController < ApplicationController
  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]
  before_action :set_transaction, only: :create

  def index
    @categories = Current.family.categories.alphabetically

    render layout: "settings"
  end

  def new
    @category = Current.family.categories.new color: Category::COLORS.sample
    set_categories
  end

  def merge
    @categories = Current.family.categories.alphabetically
  end

  def create
    @category = Current.family.categories.new(category_params)

    if @category.save
      @transaction.update(category_id: @category.id) if @transaction

      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      set_categories
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.destroy

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def destroy_all
    Current.family.categories.destroy_all
    redirect_back_or_to categories_path, notice: "All categories deleted"
  end

  def bootstrap
    Current.family.categories.bootstrap!

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def perform_merge
    sources = Current.family.categories.where(id: params[:source_ids])
    unless sources.any?
      return redirect_to merge_categories_path, alert: t(".invalid_categories")
    end

    target = merge_target_category
    unless target
      return redirect_to merge_categories_path, alert: t(".target_not_found")
    end

    merger = Category::Merger.new(
      family: Current.family,
      target_category: target,
      source_categories: sources
    )

    if merger.merge!
      redirect_to categories_path, notice: t(".success", count: merger.merged_count)
    else
      redirect_to merge_categories_path, alert: t(".no_categories_selected")
    end
  rescue Category::Merger::UnauthorizedCategoryError => e
    redirect_to merge_categories_path, alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    redirect_to merge_categories_path, alert: e.record.errors.full_messages.to_sentence
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:id])
    end

    def set_categories
      @categories = unless @category.parent?
        Current.family.categories.alphabetically.roots.where.not(id: @category.id)
      else
        []
      end
    end

    def set_transaction
      if params[:transaction_id].present?
        @transaction = Current.family.transactions.find(params[:transaction_id])
      end
    end

    def category_params
      params.require(:category).permit(:name, :color, :parent_id, :lucide_icon)
    end

    def merge_target_category
      if params[:new_target_name].present?
        Current.family.categories.create!(
          name: params[:new_target_name],
          color: params[:new_target_color].presence || Category::COLORS.sample,
          lucide_icon: params[:new_target_icon].presence || Category.suggested_icon(params[:new_target_name])
        )
      else
        Current.family.categories.find_by(id: params[:target_id])
      end
    end
end
