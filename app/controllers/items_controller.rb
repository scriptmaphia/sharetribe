require 'rubygems'
require 'google_geocode'

class ItemsController < ApplicationController
  
  before_filter :logged_in, :except => [ :index, :show, :hide, :search ]
  
  # temporarily off, cos breaks the tests.. :)
  # caches_action :index, :cache_path => :index_cache_path.to_proc
  # use sweeper to decet changes that require cache expiration. 
  # Some non-changing methods are excluded. not sure if it helps anything for performance?
  cache_sweeper :item_sweeper, :except => [:show, :index, :new, :search]
  
  def index
    save_navi_state(['items','browse_items','',''])
    @letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZÅÄÖ#".split("")
    @item_titles = Item.find(:all, 
                             :conditions => "status <> 'disabled'" + get_visibility_conditions("item"), 
                             :select => "DISTINCT title", 
                             :order => 'title ASC').collect(&:title)
    
    @item_title_hash = {}
    
    #doing hash with all the letters as key values
    @letters.each do |letter|
      @item_title_hash[letter] = Array.new
    end
    
    @item_titles.each do |title|
      if @item_title_hash.has_key?(title[0,1].upcase)
        @item_title_hash[title[0,1].upcase].push(title)
      elsif title[0,2].eql?("ä") || title[0,2].eql?("Ä")
          @item_title_hash["Ä"].push(title)
      elsif title[0,2].eql?("ö") || title[0,2].eql?("Ö")
          @item_title_hash["Ö"].push(title)
      elsif title[0,2].eql?("å") || title[0,2].eql?("Å")
          @item_title_hash["Å"].push(title)
      else
          @item_title_hash["#"].push(title)
      end  
    end
  end
  
  def show
    @title = URI.unescape(params[:id])
    @items = Item.find(:all, :conditions => ["title = ? AND status <> 'disabled'" + get_visibility_conditions("item"), @title])
    render :update do |page|
      if @items.size > 0
        page[item_div_title(@title)].replace_html :partial => "item_title_link_and_owners"
      else
        flash[:error] = :no_item_with_such_title
        page["announcement_div"].replace_html :partial => 'layouts/announcements'
      end    
    end  
  end
  
  def hide
    @title = URI.unescape(params[:id])
    render :update do |page|
      page[item_div_title(@title)].replace_html :partial => "item_title_link", :locals => { :item_title => @title }
    end
  end
  
  def new
    @item = Item.new
    @form_path = items_path
    @cancel_path = cancel_create_person_items_path(@current_user)
    @method = :post
    render :partial => "new"
  end
  
  def create
    get_visibility(:item)
    @item = Item.new(params[:item])
    @person = @item.owner
    @conditions = get_visibility_conditions("item")
    render :update do |page|
      if !is_current_user?(@person)
        flash[:error] = :operation_not_permitted
      elsif @current_user.save_item(@item)
        @item.save_group_visibilities(params[:groups])
        flash[:notice] = :item_added
        flash[:error] = nil
        page["profile_items"].replace_html :partial => "people/profile_item", 
                                           :collection => @current_user.available_items(@conditions),
                                           :as => :item, 
                                           :spacer_template => "layouts/dashed_line"
        page["profile_add_item"].replace_html :partial => "people/profile_add_item"                                   
      else
        flash[:notice] = nil
        flash[:error] = translate_announcement_error_message(@item.errors.full_messages.first)
      end
      page["announcement_div"].replace_html :partial => 'layouts/announcements'            
    end
  end
  
  def edit
    @item = Item.find(params[:id])
    @object_visibility = @item.visibility
    @groups = @item.groups
    @form_path = item_path(@item)
    @cancel_path = cancel_update_person_item_path(@item.owner, @item)
    @method = :put
    render :partial => "new"
  end
  
  def update
    @item = Item.find(params[:id])
    @person = @item.owner
    get_visibility(:item)
    render :update do |page|
      if !is_current_user?(@item.owner)
        flash[:error] = :operation_not_permitted
        page["item_" + @item.id.to_s].replace_html :partial => 'people/profile_item_inner', :locals => {:item => @item}
      else
        @item.title = params[:item][:title]
        @item.description = params[:item][:description]
        @item.visibility = params[:item][:visibility]
        @item.amount = params[:item][:amount]
        if @current_user.save_item(@item)
          @item.save_group_visibilities(params[:groups])
          flash[:notice] = :item_updated
          flash[:error] = nil
          page["item_" + @item.id.to_s].replace_html :partial => 'people/profile_item_inner', :locals => {:item => @item}
        else
          flash[:error] = translate_announcement_error_message(@item.errors.full_messages.first)
        end  
      end
      page["announcement_div"].replace_html :partial => 'layouts/announcements'
    end
  end
  
  def destroy
    logger.info "this is controller"
    @item = Item.find(params[:id])
    @person = @item.owner
    @conditions = get_visibility_conditions("item")    
    render :update do |page|
      if !is_current_user?(@person)
        flash[:error] = :operation_not_permitted
      else
        @item.disable
        flash[:notice] = [ :removed_item, h(@item.title), :undo, undo_destroy_person_item_path(@current_user, @item) ]
        page["profile_items"].replace_html :partial => "people/profile_item", 
                                           :collection => @current_user.available_items(@conditions),
                                           :as => :item, 
                                           :spacer_template => "layouts/dashed_line"                             
      end
      page["announcement_div"].replace_html :partial => 'layouts/announcements'          
    end
  end
  
  def undo_destroy
    @person = Person.find(params[:person_id])
    return unless must_be_current_user(@person)
    @item = Item.find(params[:id])
    @item.enable
    flash[:notice] = [:cancelled_deletion_of_item, @item.title]
    redirect_to @person
  end
  
  def search
    save_navi_state(['items', 'search_items'])
    if params[:q]
      query = (params[:q].length > 0) ? "*" + params[:q] + "*" : ""
      items = search_items(query)
      @items = items.paginate :page => params[:page], :per_page => per_page
    end
  end
  
  # Search used for auto completion
  def search_by_title
    @items = Item.find(:all, 
                       :conditions => ["title LIKE ?", "%#{params[:search]}%"], 
                       :select => "DISTINCT title",
                       :order => 'title ASC')
  end
  
  def borrow
    @person = Person.find(params[:person_id])
    return unless must_not_be_current_user(@person, :cant_borrow_from_self)
    @items = []
    if params[:id]
      @items << Item.find(params[:id])
    else
      @items = Item.find(params[:items], :order => "title")
    end   
    @conversation = Conversation.new
  end
  
  def view_description
    set_description_visibility(true)
  end
  
  def hide_description
    set_description_visibility(false)
  end
  
  def cancel_create
    @person = Person.find(params[:person_id])
    render :update do |page|
      page["profile_add_item"].replace_html :partial => "people/profile_add_item"
    end
  end
  
  def cancel_update
    @person = Person.find(params[:person_id])
    @item = Item.find(params[:id])
    render :update do |page|
      page["item_" + @item.id.to_s].replace_html :partial => 'people/profile_item_inner', :locals => {:item => @item}
    end
  end
  
  # Shows an item with a specific id (params[:id]) on the map.
  def map
    @item = Item.find(params[:id])
    @title = @item.title.capitalize
    gg = GoogleGeocode.new YAML.load_file(RAILS_ROOT + '/config/gmaps_api_key.yml')[ENV['RAILS_ENV']]
    begin
      loc = gg.locate @item.owner.unstructured_address
    rescue
      flash[:error] = :item_owner_has_not_provided_location
      return
    end  
    @map = GMap.new("map_div")
    @map.control_init(:large_map => true, :map_type => false)
    @map.center_zoom_init([loc.latitude, loc.longitude], 15)
    info_text = render_to_string :partial => "items/map_item", :locals => { :item => @item }
    @map.overlay_init(GMarker.new([loc.latitude, loc.longitude], :title => @item.owner.street_address, :info_window => info_text))
  end
  
  # Shows items with a specific title (params[:id]) on the map.
  def show_on_map
    
    # if there is params[:q] we are in the search view, otherwise in the list view
    if params[:q]
      @title = params[:q]
      @items = search_items(params[:q])
    else  
      @title = URI.unescape(params[:id])
      @items = Item.find(:all, :conditions => ["title = ? AND status <> 'disabled'", @title])
    end  
    @title = @title.capitalize
    gg = GoogleGeocode.new YAML.load_file(RAILS_ROOT + '/config/gmaps_api_key.yml')[ENV['RAILS_ENV']]
    
    # If there's only one item, zoom to it, otherwise render a default view.
    if @items.size > 1
      central_loc = gg.locate "Seurasaari, Helsinki"
      zoom = 12
    else
      if !@items.first.owner.street_address || @items.first.owner.street_address == ""
        flash[:error] = :item_owner_has_not_provided_location
        render :action => :map and return
      end  
      begin
        central_loc = gg.locate @items.first.owner.unstructured_address
      rescue
        flash[:error] = :item_owner_has_not_provided_location
        render :action => :map and return
      end    
      zoom = 15
    end
    
    # Initialize map      
    @map = GMap.new("map_div")
    @map.control_init(:large_map => true, :map_type => false)
    @map.center_zoom_init([central_loc.latitude, central_loc.longitude], zoom)
    
    # If at least one item owner has a valid address, display it on the map; otherwise don't render map.
    at_least_one_is_valid = false;
    @items.each do |item|
      if !item.owner.street_address || item.owner.street_address == ""
        flash[:warning] = :all_item_owners_have_not_provided_their_info
        next
      end
      begin
        loc = gg.locate item.owner.unstructured_address
        info_text = render_to_string :partial => "items/map_item", :locals => { :item => item }
        @map.overlay_init(GMarker.new([loc.latitude, loc.longitude], :title => item.owner.name, :info_window => info_text))
        at_least_one_is_valid = true;
      rescue
        flash[:warning] = :all_item_owners_have_not_provided_their_info
      end  
    end
    unless at_least_one_is_valid 
      @map = nil
      flash[:error] = :item_owners_have_not_provided_their_location
      flash[:warning] = nil
    end   
     
    render :action => :map 
  end
  
  # Checks if the given amount of this item is available
  # on the given time period
  def availability
    @item = Item.find(params[:item])
    pick_up_time =  DateTime.parse(params[:picking_up_time])
    return_time = DateTime.parse(params[:returning_time])
    available_amount = @item.get_availability(pick_up_time, return_time)
    enough_available = (available_amount >= params[:amount].to_i)
    render :partial => "availability", 
           :locals => { :available_amount => available_amount, :enough_available => enough_available }
  end
  
  # Checks how many pieces of each item there are available
  # on the given time period
  def availability_of_all_items
    @items = Item.find(params[:items])
    pick_up_time =  DateTime.parse(params[:picking_up_time])
    return_time = DateTime.parse(params[:returning_time])
    render :update do |page|
      @items.each do |item|
        available_amount = item.get_availability(pick_up_time, return_time)
        enough_available = (available_amount >= params[:amounts][@items.index(item)].to_i)
        if item
          page["reservation_item_#{item.id.to_s}"].replace_html :partial => "availability",
                                                                :locals => { :available_amount => available_amount, 
                                                                             :enough_available => enough_available }
        end
      end  
    end  
  end
  
  private
  
  def index_cache_path
    if @current_user
      "items_list/#{session[:locale]}/#{items_last_changed}/#{@current_user.id}"
    else
       "items_list/#{session[:locale]}/#{items_last_changed}/non-registered"
    end
  end
  
  def search_items(query)
    s = Ferret::Search::SortField.new(:title_sort, :reverse => false)
    Item.find_by_contents(query, {:sort => s}, {:conditions => "status <> 'disabled'" + get_visibility_conditions("item")})
  end
  
  def set_description_visibility(visible)
    partial = visible ? "items/title_and_description" : "items/title_no_description"
    @item = Item.find(params[:id])
    @person = Person.find(params[:person_id])
    render :update do |page|
      page["item_description_#{@item.id}"].replace_html :partial => partial, 
                                                        :locals => { :item => @item }          
    end
  end
  
end
