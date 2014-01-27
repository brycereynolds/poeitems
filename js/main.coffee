jQuery ->

  # Adding filter to Array prototype
  Array::filter = (func) -> x for x in @ when func(x)

  # Simplify jQuery getJSON so it just returns a request object
  getJSON = (url) ->
      $.getJSON "#{url}.json"

  # On initial load we want to get item details
  items = {
    amulet: {}
    belt: {}
    ring: {}

    boot: {}
    chest: {}
    glove: {}
    helmet: {}
    shield: {}

    axe: {}
    bow: {}
    claw: {}
    dagger: {}
    mace: {}
    quiver: {}
    rapier: {}
    sceptre: {}
    staff: {}
    sword: {}
    wand: {}
  }

  window.items = items = {}
  modNameLookup = {}
  mods = {}

  # Load armours, weapons and jewelry
  getJSON("/poeitems/schema/items").done( (obj) ->
    window.items = items = obj
  )

  # List for converting "+23 to Intelligence" into the string used by MOD Compendium
  getJSON("/poeitems/schema/mod_name_lookup").done( (obj) ->
    window.modNameLookup = modNameLookup = obj

    # After we get name lookups get mods. This waits b/c
    # we need to know what our possible hybrid rolls are
    getJSON("/poeitems/schema/mods").done( (obj) ->

        # For our mods we want to setup the hybrid rolls
        _hybridValues = (mod) ->
          return if !modNameLookup.hybrids[mod.description]
          type = mod.description

          delete mod.min_value
          delete mod.max_value

          if type == "Light Radius / +Accuracy Rating"
            matches = mod.value.match /([0-9]+) \/ ([0-9]+) to ([0-9]+)/i
            if matches
              [ _
                mod.value_one
                mod.value_min_two
                mod.value_max_two
              ] = matches

          else
            matches = mod.value.match /([0-9]+) to ([0-9]+) \/ ([0-9]+) to ([0-9]+)/i
            if matches
              [ _
                mod.value_min_one
                mod.value_max_one
                mod.value_min_two
                mod.value_max_two
              ] = matches

          if !matches then console.log("ERROR: Failed match after json load for", mod)

        _hybridValues mod for mod in obj

        window.modsLookup = modsLookup = obj
    );

  );


  class Items extends Backbone.Collection
    model: Item



  class Item extends Backbone.Model

    defaults: ->
      {
        prefixes: 0
        suffixes: 0
      }

    computeExplicitMods: ->
      console.log("In the model", this.toJSON())
      ###
      1. Loop through each mod.
      2. Find out what number variation is in use.
      3. Store numbers and replace them in string with #
      4. Find all matching mods via mod_name_lookup.json file (modNameLookup)
      5. Return possible mods for that item via item type and level against mods.json (itemTypeLookup)
      6. Limit mods to those mods existing in both lists (modNameLookup + itemTypeLookup = modList)
      7. If mods are found for more than one string it means a hybrid has been rolled (treat number comparison differently)
      8. Find out what level each mod rolled by looking at numbers and modList
      9. Give each roll a score (actual roll / possible roll)
      ###

      type        = @.get('type')
      itemLevel   = @.get('item_level')
      affinities  = @.get('affinities')

      # All possible rolls for this item given its level and type
      allPossibleRollsForThisItem = modsLookup.filter (x) -> x.level <= itemLevel and x[type] in affinities

      # Breaks mod strings up into actual values to be used. Returns mods with nameLookup
      # which is a list of all their possible roll categories
      _processSingleMod = (string) ->
        mod = {orig: string, finalized: false}

        ###
        # Mod Variations
        1-2         [min]-[max]
        +11%        +[num]%
        +125        +[num]
        43%         [num]%
        4.8         [num]
        ###

        # Figure out number type
        if /[1-9]+-[1-9]+/i.test(string)
          [_, mod.min_value, mod.max_value] = string.match /([1-9]+)-([1-9]+)/i
          mod.type = '#-#'

        else if /\+[1-9]+%/i.test(string)
          [_, mod.value] = string.match /\+([1-9]+)%/i
          mod.type = '+#%'

        else if /\+[1-9]+/i.test(string)
          [_, mod.value] = string.match /\+([1-9]+)/i
          mod.type = '+#'

        else if /[1-9]+%/i.test(string)
          [_, mod.value] = string.match /([1-9]+)%/i
          mod.type = '#%'

        else if /[1-9]+/i.test(string)
          [_, mod.value] = string.match /([1-9]+)/i
          mod.type = '#'

        mod.str = string.toLowerCase().replace /[1-9]+/i, '#'
        mod.nameLookup = if modNameLookup.lookup[mod.str] then modNameLookup.lookup[mod.str] else "Unknown"

        mod

      mods = []
      mods.push _processSingleMod string for string in @.get('explicit')


      # console.log "IN MODS AREA", mods

      # For each mod we have to pick a roll - then roll all the other mods in
      # light of that chosen roll

      # For each mod - considering what the other mods - figure out what the real roll is
      _decideModRoll = (mod) =>

        # Some mods we do not roll individually - they are the secondary hybrid roll
        if "Base Stun Recovery +%" in mod.nameLookup then mod.finalized = true
        if mod.finalized then return mod

        mod.roll = {}

        # console.log "MOD ROLL SPOT", mod

        # Only concern ourselves with rolls that this item can actually roll - this is
        # cross-checking the nameLookup with allPossibleRollsForThisItem
        possibleRolls = allPossibleRollsForThisItem.filter (x) ->
          x.description in mod.nameLookup and x.level <= itemLevel and x[type] in affinities

        val = parseInt mod.value

        # When we have one matching mod in nameLookup we can assume this is
        # the correct roll.
        if mod.nameLookup.length == 1

          mod.roll = (possibleRolls.filter (x) -> x.min_value <= val && x.max_value >= val)[0]
          mod.higher_rolls = possibleRolls.filter (x) -> x.max_value > val
          mod.lower_rolls = possibleRolls.filter (x) -> x.max_value < val

        # When there are more than one mods found in nameLookup then a cross-checking
        # with the other mods is required to determine if a hybrid was rolled
        else

          hybrid = {}

          # Process string by looking at all other mods - pull hybrids into
          # this roll so that we are not processing them twice.

          _compareNameLookupWithOtherMods = (string) ->
            # Check if this string is a hybrid
            # Yes: look at all other mods and decide if we have all required parts for this hybrid
            # No: save this mod b/c when no hybrids are found it is the roll

            if string == "Local Armour And Energy Shield +% / Base Stun Recovery +%"
              # Find the base stun roll on our mods

              hybrid = (mods.filter (x) -> "Base Stun Recovery +%" in x.nameLookup)[0]

            return if !hybrid

            ###
            The second value is always considered the "hybrid" and will
            always be run via processing the first roll.

            All hybrids run this accept the Light Radius one
              value_min_one: "42"
              value_max_one: "50"

              value_min_two: "14"
              value_max_two: "15"
            ###

            # At this point we have a specific hybrid based on our 'string'

            hybrid.finalized = true

            # What did our hybrid roll
            possibleHybridRolls = allPossibleRollsForThisItem.filter (x) ->
              x.description == string and x.level <= itemLevel and x[type] in affinities

            hybrid.roll = (possibleHybridRolls.filter (x) ->
              x.value_min_two <= hybrid.value and x.value_max_two >= hybrid.value
            )[0]

            hybrid.higher_rolls = possibleRolls.filter (x) -> x.value_max_two > val
            hybrid.lower_rolls = possibleRolls.filter (x) -> x.value_max_two < val

            if hybrid.roll then mod.hybrid = hybrid

          _compareNameLookupWithOtherMods string for string in mod.nameLookup

        # If we do not have a mod by this point then we may have a weird roll
        if !mod.roll

        else
          if mod.roll.prefix_suffix == "Suffix"
            @.set {'suffixes': @.get('suffixes') + 1}
          else
            @.set {'prefixes': @.get('prefixes') + 1}

      # / _decideModRoll



      _decideModRoll mods[0]
      _decideModRoll mods[1]
      _decideModRoll mods[2]
      _decideModRoll mods[3]
      _decideModRoll mods[4]

      @.set {'mods': mods}

      # @.trigger 'mods_updated'

      console.log("Item", @.toJSON())

      # Once done add model to processedItems - 




  class PasteBinView extends Backbone.View
    model         : Item
    el            : '#pasteBinSection'
    template      : $ '#paste-bin-section-tmpl'
    mod_template  : $ '#roll-item-mod-tmpl'

    events:
      'click #rollItemButton':  '_eventRollItem'

    initialize: ->
      @render()
      return @

    render: ->
      $(@el).append(_.template(@template.html()))

    renderMods: ->
      $('#roll_mod_holder', @el).html(_.template(@mod_template.html(), {model: @model.toJSON()}))

    _eventRollItem: (e) ->
      e && e.preventDefault
      @rollItem $('#pasteHolder').val()

    rollItem: (item) ->
      return false if !item

      # Remove noise
      item = item.replace("You cannot use this item. Its stats will be ignored. Please remove it.\n--------", "")

      # The raw text will be separated by ------- and our
      # last value is always explicit mods (its hard to identify
      # them otherwise)
      sections = item.split('--------').reverse()

      # Turns strings into parameters onto an Item model
      @model = new Item();
      @processRawSection _i + 1, section.split('\n') for section in sections

      # Figure out what the explicit mods are on this Item
      @model.computeExplicitMods()

      processedItems.add(@model)

      @.renderMods()

    processRawSection: (count, rawSection) ->
      section = rawSection.filter (x) -> x.trim() != ""

      identity = if count != 1 then false else "explicit"
      identify = (string) ->
        return false if identity

        if /rarity:/i.test(string)
          identity = "item_type"

        else if /requirements/i.test(string)
          identity = "requirements"

        else if /itemlevel/i.test(string)
          identity = "item_level"

        else if /sockets/i.test(string)
          identity = "sockets"

        else if /quality|augmented/i.test(string)
          identity = "implicit"

      identify string for string in section

      # Based on the identity of our section we want to do further
      # formating of the data
      switch identity

        # Eg.
        # [
        #   "+33 to Intelligence",
        #   "113% increased Energy Shield",
        #   "+142 to maximum Energy Shield",
        #   "Reflects 6 Physical Damage to Melee Attackers"
        # ]
        when "explicit" then @model.set({'explicit': section})

        # Eg.
        # [
        #   "Rarity: Rare",
        #   "Hypnotic Jack",
        #   "Vaal Regalia"
        # ]
        when "item_type"
          if section[0]
            rarity = section[0].toLowerCase().replace("rarity:", "").trim()

          if section[1]
            name = section[1]

          if section[2]
            pretty_type = section[2]

            cleanType = section[2].toLowerCase().replace("'", "")

            if items[cleanType]
              foundItem = items[cleanType]

              type = foundItem.type
              level = foundItem.level
              armour = foundItem.armour
              evasion = foundItem.evasion
              energy_shield = foundItem.energy_shield
              req_str = if foundItem.req_str then parseInt foundItem.req_str else 0
              req_dex = if foundItem.req_dex then parseInt foundItem.req_dex else 0
              req_int = if foundItem.req_int then parseInt foundItem.req_int else 0

              affinities = ['Yes']
              switch
                when req_str > 0 and !req_dex and !req_int
                  affinities.push('Yes (str)')
                  affinities.push('Yes (str-only)')
                when !req_str and req_dex > 0 and !req_int
                  affinities.push('Yes (dex)')
                  affinities.push('Yes (dex-only)')
                when !req_str and !req_dex and req_int > 0
                  affinities.push('Yes (int)')
                  affinities.push('Yes (int-only)')
                when req_str > 0 and req_dex > 0 and !req_int
                  affinities.push('Yes (str)')
                  affinities.push('Yes (dex)')
                  affinities.push('Yes (dex-str)')
                when req_str > 0 and !req_dex and req_int > 0
                  affinities.push('Yes (str)')
                  affinities.push('Yes (int)')
                  affinities.push('Yes (int-str)')
                when !req_str and req_dex > 0 and req_int > 0
                  affinities.push('Yes (dex)')
                  affinities.push('Yes (int)')
                  affinities.push('Yes (int-dex)')

          @model.set {
            "rarity"        : if rarity then rarity else null
            "name"          : if name then name else null
            "pretty_type"   : if pretty_type then pretty_type else null
            "type"          : if type then type else null
            "level"         : if level then level else null
            "armour"        : if armour then armour else null
            "evasion"       : if evasion then evasion else null
            "energy_shield" : if energy_shield then energy_shield else null
            "req_str"       : if req_str then req_str else null
            "req_dex"       : if req_dex then req_dex else null
            "req_int"       : if req_int then req_int else null
            "affinities"    : affinities
          }

        # Eg.
        # [
        #   "Requirements:",
        #   "Level: 68",
        #   "Str (gem): 96 (unmet)",
        #   "Dex (gem): 99 (unmet)",
        #   "Int: 194 (unmet)"
        # ]
        when "requirements" then @model.set({"requirements": section})

        # Eg.
        # [
        #   "Itemlevel: 75"
        # ]
        when "item_level" 
          @model.set({
            "item_level": section[0].toLowerCase().replace("itemlevel:", "").trim()
          })

        # Eg.
        # [
        #   "Sockets: G-B-B-B-R B "
        # ]
        when "sockets"
          @model.set({
            "sockets": section[0].toLowerCase().replace("sockets:", "").trim()
          })

        # Eg.
        # [
        #   "Quality: +20% (augmented)",
        #   "Energy Shield: 810 (augmented)"
        # ]
        when "implicit" then @model.set({"implicit": section})


  processedItems = new Items

  pasteBinView = new PasteBinView