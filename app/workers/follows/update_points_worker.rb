module Follows
  class UpdatePointsWorker
    include Sidekiq::Worker
    include FieldTest::Helpers
    sidekiq_options queue: :low_priority, retry: 10

    def perform(article_id, user_id)
      article = Article.find_by(id: article_id)
      user = User.find_by(id: user_id)
      return unless article && user

      adjust_other_tag_follows_of_user(user.id)
      followed_tag_names = user.cached_followed_tag_names
      article.decorate.cached_tag_list_array.each do |tag_name|
        if followed_tag_names.include?(tag_name)
          recalculate_tag_follow_points(tag_name, user)
        end
      end
    end

    def recalculate_tag_follow_points(tag_name, user)
      tag = Tag.find_by(name: tag_name)
      follow = Follow.follower_tag(user.id).where(followable_id: tag.id).last

      follow.implicit_points = calculate_implicit_points(tag, user)
      follow.save
    end

    def calculate_implicit_points(tag, user)
      last_100_reactable_ids = user.reactions.where(reactable_type: "Article", points: 0..)
        .pluck(:reactable_id).last(100)
      last_100_long_page_view_article_ids = user.page_views.where(time_tracked_in_seconds: 45..)
        .pluck(:article_id).last(100)
      articles = Article.where(id: last_100_reactable_ids + last_100_long_page_view_article_ids)
      tags = articles.pluck(:cached_tag_list).compact.flat_map { |list| list.split(", ") }
      occurrences = tags.count(tag.name)
      bonus = inverse_popularity_bonus(tag)
      finalized_points(occurrences, bonus, user)
    end

    def adjust_other_tag_follows_of_user(user_id)
      # As we bump one follow up, we should also give a slight penalty
      # to other follows to ensure re-balancing of overall points
      # This will help stale tags fade after a temporary interest bump

      # 0.98 is used to ensure this is "a very small amount"
      # And percentage seems to makes sense, as it will be relative to
      # size of current points.

      # That number could be adjusted at any point if we have reason to
      # believe it is too much or too little.
      Follow.follower_tag(user_id).order(Arel.sql("RANDOM()")).limit(5).each do |follow|
        follow.update_column(:points, (follow.points * 0.98))
      end
    end

    def inverse_popularity_bonus(tag)
      # Let's give a bonus to "less popular" tags on the platform
      # To help balance the weight of popular topic.
      # On DEV, javascript has way more taggings than rust, for example, so we can
      # help rust outweigh JS in this calculation slightly.
      # The bonus will be applied to the logarithmic scale, as to blunt any outsized impact.
      top_100_tag_names = cached_app_wide_top_tag_names
      top_100_tag_names.index(tag.name) || (top_100_tag_names.size * 1.5)
    end

    def finalized_points(occurrences, bonus, user)
      test_variant = field_test(:follow_implicit_points, participant: user)
      case test_variant
      when "no_implicit_score"
        0
      when "half_weight_after_log"
        Math.log(occurrences + bonus + 1) * 0.5
      when "double_weight_after_log"
        Math.log(occurrences + bonus + 1) * 2.0
      when "double_bonus_before_log"
        Math.log(occurrences + (bonus * 2) + 1)
      when "without_weighting_bonus"
        Math.log(occurrences + 1)
      else # base - Our current "default" implementation
        Math.log(occurrences + bonus + 1) # + 1 in all cases is to avoid log(0) => -infinity
      end
    end

    def cached_app_wide_top_tag_names
      Rails.cache.fetch("top-100-tags") do
        Tag.order(hotness_score: :desc).limit(100).pluck(:name)
      end
    end
  end
end
