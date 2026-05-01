require "test_helper"

class CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @transaction = transactions :one
    ensure_tailwind_build
  end

  test "index" do
    get categories_url
    assert_response :success
    assert_select "#category_#{categories(:food_and_drink).id} > [data-testid='category-content']", count: 1
    assert_select "#category_#{categories(:food_and_drink).id} > [data-testid='category-actions']", count: 1
    assert_select "#category_#{categories(:food_and_drink).id} [data-testid='category-name']", text: categories(:food_and_drink).name
  end

  test "new" do
    get new_category_url
    assert_response :success
  end

  test "create" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
  end

  test "create fails if name is not unique" do
    assert_no_difference "Category.count" do
      post categories_url, params: {
        category: {
          name: categories(:food_and_drink).name,
          color: Category::COLORS.sample } }
    end

    assert_response :unprocessable_entity
  end

  test "create and assign to transaction" do
    color = Category::COLORS.sample

    assert_difference "Category.count", +1 do
      post categories_url, params: {
        transaction_id: @transaction.id,
        category: {
          name: "New Category",
          color: color } }
    end

    new_category = Category.order(:created_at).last

    assert_redirected_to categories_url
    assert_equal "New Category", new_category.name
    assert_equal color, new_category.color
    assert_equal @transaction.reload.category, new_category
  end

  test "edit" do
    get edit_category_url(categories(:food_and_drink))
    assert_response :success
  end

  test "update" do
    new_color = Category::COLORS.without(categories(:income).color).sample

    assert_changes -> { categories(:income).name }, to: "New Name" do
      assert_changes -> { categories(:income).reload.color }, to: new_color do
        patch category_url(categories(:income)), params: {
          category: {
            name: "New Name",
            color: new_color } }
      end
    end

    assert_redirected_to categories_url
  end

  test "bootstrap" do
    # 22 default categories minus 2 that already exist in fixtures (Income, Food & Drink)
    assert_difference "Category.count", 20 do
      post bootstrap_categories_url
    end

    assert_redirected_to categories_url
  end

  test "merge selected categories into a new category" do
    source = @family.categories.create!(
      name: "Coffee Shops",
      color: "#000000",
      lucide_icon: "coffee"
    )
    transactions(:one).update!(category: source)

    assert_difference "Category.count", 0 do
      post perform_merge_categories_path, params: {
        new_target_name: "Dining",
        new_target_color: "#111111",
        new_target_icon: "utensils",
        source_ids: [ source.id ]
      }
    end

    target = Category.find_by!(family: @family, name: "Dining")
    assert_redirected_to categories_path
    assert_equal target, transactions(:one).reload.category
    assert_not Category.exists?(source.id)
  end

  test "merge ignores categories outside current family" do
    other = families(:empty).categories.create!(
      name: "Other Family Category",
      color: "#000000",
      lucide_icon: "shapes"
    )

    post perform_merge_categories_path, params: {
      target_id: categories(:income).id,
      source_ids: [ other.id ]
    }

    assert_redirected_to merge_categories_path
    assert Category.exists?(other.id)
  end
end
