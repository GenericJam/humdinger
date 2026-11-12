defmodule Humdinger.Showcase do
  @moduledoc """
  Registry + contract for the component gallery.

  Each showcased component is a module that `use Humdinger.Showcase` and
  implements `entry/0` (metadata) and `examples/0` (a list of
  `#{inspect(__MODULE__)}.Example`). Register them at boot (see
  `Humdinger.App.on_start/0`). The generic `GalleryScreen` and
  `ComponentScreen` read this registry — so **adding a component to the gallery
  is one module + one register call, no new screen**.

  ## Author a component showcase

      defmodule MyApp.Showcase.Components.Badge do
        use Humdinger.Showcase
        alias Humdinger.Showcase.Example

        @impl true
        def entry do
          %{slug: :badge, name: "Badge", category: "Data display", order: 0,
            description: "A small status/count label."}
        end

        @impl true
        def examples do
          [%Example{title: "Colors", description: "One per semantic token.",
                    code: "<Badge color={:primary} text=\\"New\\" />",
                    render: fn _assigns -> badge_row() end}]
        end
      end

  Then `Humdinger.Showcase.register(MyApp.Showcase.Components.Badge)`.

  ## Interactive / overlay components

  Static components only need `entry/0` + `examples/0` (each example's `render`
  returns an inline preview node). Components that need state or an overlay
  (Drawer, Modal, …) also override:

    * `mount/1`  — seed the screen's assigns (`socket -> socket`)
    * `handle/2` — react to a tapped tag (`(tag, socket) -> socket`)
    * `overlay/1` — a node rendered at the **screen root** (`assigns -> node | nil`),
      so a drawer's panel stacks over the whole page while the example card
      shows only the inline "Open" buttons.

  `ComponentScreen` delegates its `mount`, tap events, and root overlay to
  these, so every component drives itself through one generic screen.
  """

  alias Humdinger.Showcase.Kit

  @pt_key {__MODULE__, :components}

  defmodule Example do
    @moduledoc """
    One showcased example: a `title`, a short `description`, the `code` to show
    (a plain string — device builds ship no source to read), and a `render`
    function returning the live preview node.
    """
    @enforce_keys [:title, :render]
    defstruct [:title, :description, :code, :render]

    @type t :: %__MODULE__{
            title: String.t(),
            description: String.t() | nil,
            code: String.t() | nil,
            render: (map() -> map())
          }
  end

  @typedoc "Component metadata returned by `entry/0` (the registry adds `:module`)."
  @type entry :: %{
          required(:slug) => atom(),
          required(:name) => String.t(),
          required(:category) => String.t(),
          optional(:description) => String.t(),
          optional(:order) => integer()
        }

  @callback entry() :: entry()
  @callback examples() :: [Example.t()]
  @callback mount(socket :: term()) :: term()
  @callback handle(tag :: term(), socket :: term()) :: term()
  @callback overlay(assigns :: map()) :: map() | nil
  @callback card_preview() :: map()
  @callback props() :: [%{required(:name) => String.t(), optional(atom()) => String.t()}]
  @doc """
  Handle a value-carrying event — `{:change, tag, value}` from a Toggle, Slider,
  TextField, … — as opposed to `handle/2`'s bare taps.
  """
  @callback handle_change(tag :: term(), value :: term(), socket :: term()) :: term()
  @optional_callbacks mount: 1,
                      handle: 2,
                      handle_change: 3,
                      overlay: 1,
                      card_preview: 0,
                      props: 0

  @doc "Register a showcase component module. Overwrites any prior registration for its slug."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    slug = module.entry().slug
    :persistent_term.put(@pt_key, Map.put(components(), slug, module))
    :ok
  end

  # ── The catalog ─────────────────────────────────────────────────────────────
  #
  # One entry per ported Chelekom component, and the single place that grows as
  # the port advances: `Humdinger.App.on_start/0` and the test suite both call
  # `register_all/0`, so neither can drift from the other.
  #
  # The composite tag is what lets an app write `<MishkaDrawer>` in `~MOB`.
  # Our own code calls the component's function instead, because a tag outside
  # Mob's whitelist warns and `--warnings-as-errors` treats that as a failure.
  #
  # An entry is `{showcase, tag, component}`, or `{showcase, tag, component,
  # extras}` where `extras` is a `[{tag, component}]` list. Several Chelekom
  # components are close enough to share one gallery page — a close button is an
  # action icon with a ✕, a burger is a toolbar control — but each is still its
  # own module and still deserves its own tag, so the fourth element registers
  # the companions the page documents.
  @catalog [
    {Humdinger.Showcase.Components.Drawer, :mishka_drawer, MobMishka.Components.MishkaDrawer},
    {Humdinger.Showcase.Components.Accordion, :mishka_accordion,
     MobMishka.Components.MishkaAccordion},
    {Humdinger.Showcase.Components.Separator, :mishka_separator,
     MobMishka.Components.MishkaSeparator},
    {Humdinger.Showcase.Components.Switch, :mishka_switch, MobMishka.Components.MishkaSwitch},
    {Humdinger.Showcase.Components.Progress, :mishka_progress,
     MobMishka.Components.MishkaProgress},
    {Humdinger.Showcase.Components.Meter, :mishka_meter, MobMishka.Components.MishkaMeter},
    {Humdinger.Showcase.Components.Collapsible, :mishka_collapsible,
     MobMishka.Components.MishkaCollapsible},
    {Humdinger.Showcase.Components.Avatar, :mishka_avatar, MobMishka.Components.MishkaAvatar},
    {Humdinger.Showcase.Components.Slider, :mishka_slider, MobMishka.Components.MishkaSlider},
    {Humdinger.Showcase.Components.Dialog, :mishka_dialog, MobMishka.Components.MishkaDialog},
    {Humdinger.Showcase.Components.AlertDialog, :mishka_alert_dialog,
     MobMishka.Components.MishkaAlertDialog},
    {Humdinger.Showcase.Components.Tabs, :mishka_tabs, MobMishka.Components.MishkaTabs},
    {Humdinger.Showcase.Components.Chip, :mishka_chip, MobMishka.Components.MishkaChip},
    {Humdinger.Showcase.Components.Pill, :mishka_pill, MobMishka.Components.MishkaPill},
    {Humdinger.Showcase.Components.Mark, :mishka_mark, MobMishka.Components.MishkaMark},
    {Humdinger.Showcase.Components.Highlight, :mishka_highlight,
     MobMishka.Components.MishkaHighlight},
    {Humdinger.Showcase.Components.Checkbox, :mishka_checkbox,
     MobMishka.Components.MishkaCheckbox},
    {Humdinger.Showcase.Components.Radio, :mishka_radio, MobMishka.Components.MishkaRadio},
    {Humdinger.Showcase.Components.RadioGroup, :mishka_radio_group,
     MobMishka.Components.MishkaRadioGroup},
    {Humdinger.Showcase.Components.CheckboxGroup, :mishka_checkbox_group,
     MobMishka.Components.MishkaCheckboxGroup},
    {Humdinger.Showcase.Components.Toggle, :mishka_toggle, MobMishka.Components.MishkaToggle},
    {Humdinger.Showcase.Components.ToggleGroup, :mishka_toggle_group,
     MobMishka.Components.MishkaToggleGroup},
    {Humdinger.Showcase.Components.SegmentedControl, :mishka_segmented_control,
     MobMishka.Components.MishkaSegmentedControl},
    {Humdinger.Showcase.Components.EmptyState, :mishka_empty_state,
     MobMishka.Components.MishkaEmptyState},
    {Humdinger.Showcase.Components.Spoiler, :mishka_spoiler, MobMishka.Components.MishkaSpoiler},
    {Humdinger.Showcase.Components.ActionIcon, :mishka_action_icon,
     MobMishka.Components.MishkaActionIcon,
     [mishka_close_button: MobMishka.Components.MishkaCloseButton]},
    {Humdinger.Showcase.Components.ScrollArea, :mishka_scroll_area,
     MobMishka.Components.MishkaScrollArea},
    {Humdinger.Showcase.Components.Code, :mishka_code, MobMishka.Components.MishkaCode},
    {Humdinger.Showcase.Components.Toast, :mishka_toast, MobMishka.Components.MishkaToast},
    {Humdinger.Showcase.Components.Popover, :mishka_popover, MobMishka.Components.MishkaPopover},
    {Humdinger.Showcase.Components.Menu, :mishka_menu, MobMishka.Components.MishkaMenu},
    {Humdinger.Showcase.Components.Tooltip, :mishka_tooltip, MobMishka.Components.MishkaTooltip},
    {Humdinger.Showcase.Components.ContextMenu, :mishka_context_menu,
     MobMishka.Components.MishkaContextMenu},
    {Humdinger.Showcase.Components.Toolbar, :mishka_toolbar, MobMishka.Components.MishkaToolbar,
     [mishka_burger: MobMishka.Components.MishkaBurger]},
    {Humdinger.Showcase.Components.ColorSwatch, :mishka_color_swatch,
     MobMishka.Components.MishkaColorSwatch},
    {Humdinger.Showcase.Components.LoadingOverlay, :mishka_loading_overlay,
     MobMishka.Components.MishkaLoadingOverlay},
    {Humdinger.Showcase.Components.Skeleton, :mishka_skeleton,
     MobMishka.Components.MishkaSkeleton},
    {Humdinger.Showcase.Components.SemiCircleProgress, :mishka_semi_circle_progress,
     MobMishka.Components.MishkaSemiCircleProgress},
    {Humdinger.Showcase.Components.RollingNumber, :mishka_rolling_number,
     MobMishka.Components.MishkaRollingNumber},
    {Humdinger.Showcase.Components.PreviewCard, :mishka_preview_card,
     MobMishka.Components.MishkaPreviewCard,
     [mishka_scroller: MobMishka.Components.MishkaScroller]},
    {Humdinger.Showcase.Components.ThemeIcon, :mishka_theme_icon,
     MobMishka.Components.MishkaThemeIcon, [mishka_marquee: MobMishka.Components.MishkaMarquee]},
    {Humdinger.Showcase.Components.Field, :mishka_field, MobMishka.Components.MishkaField,
     [mishka_fieldset: MobMishka.Components.MishkaFieldset]},
    {Humdinger.Showcase.Components.NumberField, :mishka_number_field,
     MobMishka.Components.MishkaNumberField},
    {Humdinger.Showcase.Components.OtpField, :mishka_otp_field,
     MobMishka.Components.MishkaOtpField,
     [mishka_mask_input: MobMishka.Components.MishkaMaskInput]},
    {Humdinger.Showcase.Components.TagsInput, :mishka_tags_input,
     MobMishka.Components.MishkaTagsInput},
    {Humdinger.Showcase.Components.Select, :mishka_select, MobMishka.Components.MishkaSelect},
    {Humdinger.Showcase.Components.Combobox, :mishka_combobox,
     MobMishka.Components.MishkaCombobox},
    {Humdinger.Showcase.Components.Autocomplete, :mishka_autocomplete,
     MobMishka.Components.MishkaAutocomplete,
     [mishka_pills_input: MobMishka.Components.MishkaPillsInput]},
    {Humdinger.Showcase.Components.HueSlider, :mishka_hue_slider,
     MobMishka.Components.MishkaHueSlider},
    {Humdinger.Showcase.Components.AlphaSlider, :mishka_alpha_slider,
     MobMishka.Components.MishkaAlphaSlider},
    {Humdinger.Showcase.Components.AngleSlider, :mishka_angle_slider,
     MobMishka.Components.MishkaAngleSlider},
    {Humdinger.Showcase.Components.ColorPicker, :mishka_color_picker,
     MobMishka.Components.MishkaColorPicker},
    {Humdinger.Showcase.Components.ColorInput, :mishka_color_input,
     MobMishka.Components.MishkaColorInput},
    {Humdinger.Showcase.Components.Tree, :mishka_tree, MobMishka.Components.MishkaTree},
    {Humdinger.Showcase.Components.TreeSelect, :mishka_tree_select,
     MobMishka.Components.MishkaTreeSelect},
    {Humdinger.Showcase.Components.Splitter, :mishka_splitter,
     MobMishka.Components.MishkaSplitter},
    {Humdinger.Showcase.Components.OverflowList, :mishka_overflow_list,
     MobMishka.Components.MishkaOverflowList},
    {Humdinger.Showcase.Components.JsonInput, :mishka_json_input,
     MobMishka.Components.MishkaJsonInput,
     [mishka_number_formatter: MobMishka.Components.MishkaNumberFormatter]},
    {Humdinger.Showcase.Components.NavLink, :mishka_nav_link, MobMishka.Components.MishkaNavLink,
     [
       mishka_anchor: MobMishka.Components.MishkaAnchor,
       mishka_menubar: MobMishka.Components.MishkaMenubar,
       mishka_navigation_menu: MobMishka.Components.MishkaNavigationMenu,
       mishka_visually_hidden: MobMishka.Components.MishkaVisuallyHidden
     ]},
    {Humdinger.Showcase.Components.FloatingWindow, :mishka_floating_window,
     MobMishka.Components.MishkaFloatingWindow,
     [mishka_floating_indicator: MobMishka.Components.MishkaFloatingIndicator]}
  ]

  # Primitive node types this app renders ITSELF in MobBridge.kt, which mob's own
  # whitelist does not know about.
  #
  # Unlike a composite or a slot tag these are never written as `<Anchored>` in
  # ~MOB — the components emit them as raw maps, the way mishka_popover.ex
  # already emits its layout plumbing — so the sigil never sees them. This list
  # exists for one reason: `Mob.ScreenCase.assert_renderable/2` bakes its
  # renderable types out of priv/tags/*.txt at mob's compile time and flunks
  # anything outside that list, so without it every test touching a popover
  # would fail on an unknown node type.
  @native_tags [:anchored]

  @doc false
  def native_tags, do: @native_tags

  # Slot tags — the native analogue of a Chelekom `<:slot>`. A parent's expand/3
  # matches them on :type among its children and consumes them, so unlike a
  # composite they have no module, no expander and no generator files. They are
  # still TAGS, though, and the sigil validates every tag against Mob's
  # whitelist — so mix.exs reads this list and whitelists them alongside the
  # composites. Without it every use warns, and this project builds with
  # --warnings-as-errors.
  @slot_tags [
    :mishka_accordion_item,
    :mishka_alert_dialog_action,
    :mishka_checkbox_group_item,
    :mishka_dialog_trigger,
    :mishka_drawer_footer,
    :mishka_drawer_trigger,
    :mishka_floating_window_handle,
    :mishka_popover_arrow,
    :mishka_popover_close,
    :mishka_popover_description,
    :mishka_popover_title,
    :mishka_popover_trigger,
    :mishka_preview_card_trigger,
    :mishka_radio_group_option,
    :mishka_segmented_control_option,
    :mishka_select_option,
    :mishka_toggle_group_item,
    :mishka_toolbar_button,
    :mishka_toolbar_input,
    :mishka_toolbar_link,
    :mishka_toolbar_separator,
    :mishka_tree_node,
    :mishka_dialog_description,
    :mishka_dialog_footer,
    :mishka_dialog_title,
    :mishka_menu_checkbox,
    :mishka_menu_item,
    :mishka_menu_label,
    :mishka_menu_radio,
    :mishka_menu_separator,
    :mishka_menu_submenu,
    :mishka_tab,
    :mishka_empty_state_actions,
    :mishka_empty_state_indicator,
    :mishka_toast_close,
    :mishka_toast_item
  ]

  @doc "Every slot tag — a child tag consumed by its parent composite's `expand/3`."
  @spec slot_tags() :: [atom()]
  def slot_tags, do: @slot_tags

  @doc "Every showcase component module, in catalog order."
  @spec modules() :: [module()]
  def modules, do: Enum.map(@catalog, &elem(&1, 0))

  @doc """
  Every `{tag, plugin module}` composite pairing the gallery documents. The
  tags are registered by `MobMishka.register_all/0`, not from this list.
  """
  @spec composites() :: [{atom(), module()}]
  def composites, do: Enum.flat_map(@catalog, &entry_composites/1)

  defp entry_composites({_showcase, tag, component}), do: [{tag, component}]
  defp entry_composites({_showcase, tag, component, extras}), do: [{tag, component} | extras]

  @doc """
  Register every composite tag and gallery entry. Called from
  `Humdinger.App.on_start/0` at boot and from the tests.

  The composite tags are the `:mob_mishka` plugin's, so this delegates them to
  `MobMishka.register_all/0`, which registers a composite ejected with
  `mix mob_mishka.gen` (and activated through `config :mob_mishka,
  :override_namespace`) in place of the plugin's original. Registering
  `composites/0` here instead would overwrite the override the plugin's
  on_start had just registered. Calling it again at boot is harmless (same
  result), and it registers the tags in tests, where no plugin lifecycle runs.
  """
  @spec register_all() :: :ok
  def register_all do
    MobMishka.register_all()
    Enum.each(modules(), &register/1)
  end

  @doc "The raw `%{slug => module}` registry."
  @spec components() :: %{atom() => module()}
  def components, do: :persistent_term.get(@pt_key, %{})

  @doc false
  def reset, do: :persistent_term.put(@pt_key, %{})

  @doc "All entries (each augmented with `:module`), sorted by category then order then name."
  @spec all() :: [map()]
  def all do
    components()
    |> Map.values()
    |> Enum.map(&with_module/1)
    |> Enum.sort_by(&{&1.category, Map.get(&1, :order, 0), &1.name})
  end

  @doc "Entries grouped `[{category, [entry, ...]}, ...]`, categories alphabetical."
  @spec by_category() :: [{String.t(), [map()]}]
  def by_category do
    all()
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  @doc "The entry (with `:module`) for a slug, or `nil`."
  @spec get(atom()) :: map() | nil
  def get(slug) do
    case Map.get(components(), slug) do
      nil -> nil
      module -> with_module(module)
    end
  end

  defp with_module(module), do: Map.put(module.entry(), :module, module)

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Humdinger.Showcase

      @impl true
      def mount(socket), do: socket
      @impl true
      def handle(_tag, socket), do: socket
      @impl true
      def overlay(_assigns), do: nil
      @impl true
      def card_preview, do: unquote(Kit).skeleton_preview()
      @impl true
      def props, do: []
      @impl true
      def handle_change(_tag, _value, socket), do: socket

      defoverridable mount: 1,
                     handle: 2,
                     handle_change: 3,
                     overlay: 1,
                     card_preview: 0,
                     props: 0
    end
  end
end
