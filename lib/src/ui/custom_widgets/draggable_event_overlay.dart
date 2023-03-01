import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_customizable_calendar/src/domain/models/models.dart';
import 'package:flutter_customizable_calendar/src/ui/custom_widgets/custom_widgets.dart';
import 'package:flutter_customizable_calendar/src/ui/themes/themes.dart';
import 'package:flutter_customizable_calendar/src/utils/utils.dart';

/// A key holder of all DraggableEventView keys
@visibleForTesting
abstract class DraggableEventOverlayKeys {
  /// A key for the elevated (floating) event view
  static const elevatedEvent = ValueKey('elevatedEvent');
}

/// Wrapper which needs to wrap a scrollable [child] widget and display an
/// elevated event view over it.
class DraggableEventOverlay<T extends FloatingCalendarEvent>
    extends StatefulWidget {
  /// Creates an overlay for draggable event view over given [child] widget.
  const DraggableEventOverlay(
    this.event, {
    super.key,
    required this.viewType,
    required this.timelineTheme,
    this.padding = EdgeInsets.zero,
    this.onDragDown,
    this.onDragUpdate,
    this.onDragEnd,
    this.onSizeUpdate,
    this.onResizingEnd,
    this.onDropped,
    this.onChanged,
    required this.getTimelineBox,
    required this.getLayoutBox,
    required this.getEventBox,
    required this.saverConfig,
    required this.child,
  }) : assert(
          viewType != CalendarView.month,
          "MonthView isn't supported",
        );

  /// A notifier which needs to control elevated event
  final FloatingEventNotifier<T> event;

  /// Which [CalendarView]'s timeline is wrapped
  final CalendarView viewType;

  /// The timeline customization params
  final TimelineTheme timelineTheme;

  /// Offset for the overlay
  final EdgeInsets padding;

  /// Is called just after user start to interact with the event view
  final void Function()? onDragDown;

  /// Is called during user drags the event view
  final void Function(DragUpdateDetails)? onDragUpdate;

  /// Is called just after user stops dragging the event view
  final void Function()? onDragEnd;

  /// Is called during user resizes the event view
  final void Function(DragUpdateDetails)? onSizeUpdate;

  /// Is called just after user stops resizing the event view
  final void Function()? onResizingEnd;

  /// Is called just after the event is changed
  final void Function(T)? onChanged;

  /// Is called just after the event is dropped
  final void Function(T)? onDropped;

  /// Function which allows to find the timeline's [RenderBox] in context
  final RenderBox? Function() getTimelineBox;

  /// Function which allows to find the layout's [RenderBox] in context
  final RenderBox? Function(DateTime) getLayoutBox;

  /// Function which allows to find the event view's [RenderBox] in context
  final RenderBox? Function(T) getEventBox;

  /// Properties for widget which is used to save edited event
  final SaverConfig saverConfig;

  /// Scrollable view which needs to be wrapped
  final Widget child;

  @override
  State<DraggableEventOverlay<T>> createState() =>
      DraggableEventOverlayState<T>();
}

/// State of [DraggableEventOverlay] which allows to set a floating event
/// and create it's draggable [OverlayEntry].
class DraggableEventOverlayState<T extends FloatingCalendarEvent>
    extends State<DraggableEventOverlay<T>>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _overlayKey = GlobalKey<OverlayState>();
  final _layerLink = LayerLink();
  final _eventBounds = RectNotifier();
  late AnimationController _animationController;
  late Animation<double> _animation;
  late RectTween _boundsTween;
  late DateTime _pointerTimePoint;
  late Duration _startDiff;
  var _pointerLocation = Offset.zero;
  var _dragging = false;
  var _resizing = false;
  OverlayEntry? _eventEntry;
  OverlayEntry? _sizerEntry;

  OverlayState get _overlay => _overlayKey.currentState!;

  double get _minuteExtent => _hourExtent / Duration.minutesPerHour;
  double get _hourExtent => widget.timelineTheme.timeScaleTheme.hourExtent;

  int get _cellExtent => widget.timelineTheme.cellExtent;

  DraggableEventTheme get _draggableEventTheme =>
      widget.timelineTheme.draggableEventTheme;

  bool _edited = false;

  /// Needs to make interaction between a timeline and the overlay
  void onEventLongPressStart(LongPressStartDetails details) {
    _pointerLocation = details.globalPosition;

    if (_animationController.isAnimating) {
      _removeEntries();
      _animationController.reset();
    }

    final renderIds = _timelineHitTest(_pointerLocation);
    final hitTestedEvents = renderIds.whereType<RenderId<T>>();

    if (hitTestedEvents.isEmpty) return;

    final eventBox = hitTestedEvents.first;
    final event = eventBox.id;
    final layoutBox =
        renderIds.singleWhere((renderId) => renderId.id == Constants.layoutId);

    final timelineBox = widget.getTimelineBox();
    final eventPosition =
        eventBox.localToGlobal(Offset.zero, ancestor: timelineBox);
    final layoutPosition =
        layoutBox.localToGlobal(Offset.zero, ancestor: timelineBox);

    widget.event.value = event;
    _boundsTween = RectTween(
      begin: eventPosition & eventBox.size,
      end: Rect.fromLTWH(
        layoutPosition.dx,
        eventPosition.dy,
        layoutBox.size.width,
        eventBox.size.height,
      ),
    );
    _createEntriesFor(event);
    _animationController.forward();

    _dragging = true;
    _pointerTimePoint = _getTimePointAt(_pointerLocation)!;
    _startDiff = _pointerTimePoint.difference(event.start);
  }

  /// Needs to make interaction between a timeline and the overlay
  void onEventLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final dragUpdateDetails = DragUpdateDetails(
      delta: details.globalPosition - _pointerLocation,
      globalPosition: details.globalPosition,
      localPosition: details.localPosition,
    );

    widget.onDragUpdate?.call(dragUpdateDetails);
    _eventBounds.origin += dragUpdateDetails.delta;
    if (!_resetPointerLocation(details.globalPosition)) return;
    _pointerTimePoint = _getTimePointAt(_pointerLocation) ?? _pointerTimePoint;
  }

  /// Needs to make interaction between a timeline and the overlay
  void onEventLongPressEnd(LongPressEndDetails details) {
    _dragging = false;
    widget.onDragEnd?.call();
    _pointerTimePoint = _getTimePointAt(_pointerLocation) ?? _pointerTimePoint;
    _updateEventOriginAndStart();
  }

  /// Needs to make interaction between a timeline and the overlay
  void onEventLongPressCancel() => _dragging = false;

  Rect _getEventBounds(T event) {
    final eventBox = widget.getEventBox(event);

    if (eventBox == null) return Rect.zero;

    final timelineBox = widget.getTimelineBox();
    final eventPosition =
        eventBox.localToGlobal(Offset.zero, ancestor: timelineBox);

    return eventPosition & eventBox.size;
  }

  DateTime? _getTargetDayAt(Offset globalPosition) {
    final renderIds = _timelineHitTest(globalPosition);
    final targets = renderIds.whereType<RenderId<DateTime>>();

    return targets.isNotEmpty ? targets.first.id : null;
  }

  DateTime? _getTimePointAt(Offset globalPosition) {
    final dayDate = _getTargetDayAt(globalPosition);

    if (dayDate == null) return null;

    final layoutBox = widget.getLayoutBox(dayDate)!;
    final minutes = layoutBox.globalToLocal(globalPosition).dy ~/ _minuteExtent;

    return dayDate.add(Duration(minutes: minutes));
  }

  Iterable<RenderId<dynamic>> _globalHitTest(Offset globalPosition) {
    final result = HitTestResult();

    WidgetsBinding.instance.hitTest(result, globalPosition);

    return result.path
        .map((entry) => entry.target)
        .whereType<RenderId<dynamic>>();
  }

  Iterable<RenderId<dynamic>> _timelineHitTest(Offset globalPosition) {
    final timelineBox = widget.getTimelineBox();

    if (timelineBox == null) return const Iterable.empty();

    final result = BoxHitTestResult();
    final localPosition = timelineBox.globalToLocal(globalPosition);

    timelineBox.hitTest(result, position: localPosition);

    return result.path
        .map((entry) => entry.target)
        .whereType<RenderId<dynamic>>();
  }

  bool _resetPointerLocation(Offset globalPosition) {
    final timelineBox = widget.getTimelineBox();

    if (timelineBox == null) return false;

    final origin = timelineBox.localToGlobal(Offset.zero);
    final bounds = origin & timelineBox.size;

    if (!bounds.contains(globalPosition)) return false;

    // Update _pointerLocation if it's position is within the timeline rect
    _pointerLocation = globalPosition;

    return true;
  }

  void _createEntriesFor(T event) {
    _eventEntry = OverlayEntry(builder: _floatingEventBuilder);
    _overlay.insert(_eventEntry!);

    // Non-editable event can't be resized
    if (event is EditableCalendarEvent) {
      _sizerEntry = OverlayEntry(builder: _sizerBuilder);
      _overlay.insert(_sizerEntry!);
    }
  }

  void _removeEntries() {
    _eventEntry?.remove();
    _eventEntry = null;
    _sizerEntry?.remove();
    _sizerEntry = null;
  }

  void _dropEvent(T event) {
    setState(() {
      _edited = false;
    });

    if (_animationController.isAnimating) _animationController.stop();

    _boundsTween.end = _eventBounds.value;
    _animationController.reverse().whenComplete(() {
      widget.event.value = null;
      _removeEntries();
      widget.onDropped?.call(event);
    });
  }

  void _updateEventOriginAndStart() {
    final dayDate = _getTargetDayAt(_pointerLocation)!; // <- temporary
    final layoutBox = widget.getLayoutBox(dayDate)!;
    final timelineBox = widget.getTimelineBox();
    final layoutPosition =
        layoutBox.localToGlobal(Offset.zero, ancestor: timelineBox);
    final originTimePoint = _pointerTimePoint.subtract(_startDiff);
    // final originDayDate = DateUtils.dateOnly(originTimePoint);
    final originDayDate = DateUtils.dateOnly(dayDate);
    final minutes = originTimePoint.minute +
        (originTimePoint.hour * Duration.minutesPerHour);
    final roundedMinutes = (minutes / _cellExtent).round() * _cellExtent;
    final eventStartDate = originDayDate.add(Duration(minutes: roundedMinutes));
    final offset = (minutes - roundedMinutes) * _minuteExtent;

    _eventBounds.update(
      dx: layoutPosition.dx,
      dy: _eventBounds.dy - offset,
    );

    widget.event.value =
        widget.event.value!.copyWith(start: eventStartDate) as T;
  }

  void _updateEventHeightAndDuration() {
    final event = widget.event.value!;
    final dayDate = DateUtils.dateOnly(event.start);
    final minutes = event.start.minute +
        (event.start.hour * Duration.minutesPerHour) +
        (_eventBounds.height ~/ _minuteExtent);
    final roundedMinutes = (minutes / _cellExtent).round() * _cellExtent;
    final eventEndDate = dayDate.add(Duration(minutes: roundedMinutes));
    final eventDuration = eventEndDate.difference(event.start);

    _eventBounds.height = eventDuration.inMinutes * _minuteExtent;

    widget.event.value =
        (event as EditableCalendarEvent).copyWith(duration: eventDuration) as T;
  }

  void _animateBounds() =>
      _eventBounds.value = _boundsTween.transform(_animation.value)!;

  void _initAnimationController() => _animationController = AnimationController(
        duration: _draggableEventTheme.animationDuration,
        vsync: this,
      )..addListener(_animateBounds);

  void _initAnimation() => _animation = CurvedAnimation(
        parent: _animationController,
        curve: _draggableEventTheme.animationCurve,
      );

  void _eventHeightLimiter() => _eventBounds.height =
      max(_eventBounds.height, _minuteExtent * _cellExtent);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAnimationController();
    _initAnimation();
    _eventBounds.addListener(_eventHeightLimiter);
  }

  @override
  void didUpdateWidget(covariant DraggableEventOverlay<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_draggableEventTheme != oldWidget.timelineTheme.draggableEventTheme) {
      _animationController.dispose();
      _initAnimationController();
      _initAnimation();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();

    SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
      final event = widget.event.value;
      if (event == null) return;
      final dayDate = DateUtils.dateOnly(event.start);
      final layoutBox = widget.getLayoutBox(dayDate);
      if (layoutBox == null) return;
      final timelineBox = widget.getTimelineBox();
      final layoutPosition =
      layoutBox.localToGlobal(Offset.zero, ancestor: timelineBox);

      _eventBounds.update(
        dx: layoutPosition.dx,
        width: layoutBox.size.width,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.event,
      builder: (context, elevatedEvent, child) {
        if (elevatedEvent == null) return child!;

        return GestureDetector(
          onTap: () {
            _dropEvent(elevatedEvent);
          },
          onPanDown: (details) {
            final renderIds = _globalHitTest(details.globalPosition);
            final ids = renderIds.map((renderId) => renderId.id);

            if (ids.contains(Constants.sizerId)) {
              _resizing = true;
              widget.onDragDown?.call();
            } else if (ids.contains(Constants.elevatedEventId)) {
              _dragging = true;
              widget.onDragDown?.call();
            }
          },
          onPanStart: (details) {
            if (!_dragging) return;
            final event = widget.event.value!;
            _pointerLocation = details.globalPosition;
            _pointerTimePoint = _getTimePointAt(_pointerLocation)!;
            _startDiff = _pointerTimePoint.difference(event.start);
          },
          onPanUpdate: (details) {
            if (_resizing) {
              widget.onSizeUpdate?.call(details);
              _eventBounds.height += details.delta.dy;
            } else if (_dragging) {
              widget.onDragUpdate?.call(details);
              _eventBounds.origin += details.delta;
              if (!_resetPointerLocation(details.globalPosition)) return;
              _pointerTimePoint =
                  _getTimePointAt(_pointerLocation) ?? _pointerTimePoint;
            }
          },
          onPanEnd: (details) {
            if (_resizing) {
              _resizing = false;
              widget.onResizingEnd?.call();
              _updateEventHeightAndDuration();
            } else if (_dragging) {
              _dragging = false;
              widget.onDragEnd?.call();
              _pointerTimePoint =
                  _getTimePointAt(_pointerLocation) ?? _pointerTimePoint;
              _updateEventOriginAndStart();
            }
            if (!_edited) {
              setState((){
                _edited = true;
              });
            }
          },
          onPanCancel: () {
            _resizing = false;
            _dragging = false;
          },
          child: child,
        );
      },
      child: Stack(
        children: [
          NotificationListener<ScrollUpdateNotification>(
            onNotification: (event) {
              final scrollDelta = event.scrollDelta ?? 0;

              if (!_dragging && event.metrics.axis == Axis.vertical) {
                _eventBounds.update(
                  dy: _eventBounds.dy - scrollDelta,
                  height: _eventBounds.height + (_resizing ? scrollDelta : 0),
                );
              }

              return true;
            },
            child: widget.child,
          ),
          Positioned.fill(
            left: widget.padding.left,
            top: widget.padding.top,
            right: widget.padding.right,
            bottom: widget.padding.bottom,
            child: Overlay(key: _overlayKey),
          ),
          if (_edited)
            Saver(
              alignment: widget.saverConfig.alignment,
              onPressed: () {
                widget.onChanged?.call(widget.event.value!);
                _dropEvent(widget.event.value!);
                setState((){
                  _edited = false;
                  _removeEntries();
                  widget.event.value = null;
                  _resizing = false;
                  _dragging = false;
                });
              },
              child: widget.saverConfig.child,
            )
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animationController.dispose();
    _eventBounds.dispose();
    super.dispose();
  }

  Widget _elevatedEventView() => EventView(
        widget.event.value!,
        key: DraggableEventOverlayKeys.elevatedEvent,
        theme: widget.timelineTheme.floatingEventsTheme
            .copyWith(elevation: _draggableEventTheme.elevation),
        onTap: () {},
      );

  Widget _sizerView() {
    final theme = _draggableEventTheme.sizerTheme;

    return ClipOval(
      child: GestureDetector(
        onTap: () {}, // Needs to avoid unnecessary event drops
        child: ColoredBox(
          color: Colors.transparent, // Needs for hitTesting
          child: Padding(
            padding: EdgeInsets.all(theme.extraSpace),
            child: DecoratedBox(
              decoration: theme.decoration,
            ),
          ),
        ),
      ),
    );
  }

  List<Rect> _rectForDay(Rect bounds, DateTime dayDate) {
    if(widget.event.value == null) {
      return [];
    }

    List<Rect> result = [];
    final timelineBox = widget.getTimelineBox();
    // DateTime _dateBefore = dayDate.subtract(Duration(days: 1));
    DateTime _dateBefore = dayDate.copyWith();
    // DateTime _dateAfter = dayDate.copyWith();
    DateTime _dateAfter = dayDate.add(Duration(days: 1));

    int i = 1;
    while (_dateAfter.isBefore(widget.event.value!.end)) {
      final layoutBox = widget.getLayoutBox(_dateAfter)!;
      final layoutPosition =
      layoutBox.localToGlobal(Offset.zero, ancestor: timelineBox);
      result.add(Rect.fromLTWH(
        layoutPosition.dx,
        bounds.top + 24 * i * _hourExtent,
        bounds.width,
        bounds.height,
      ));
      i++;
      _dateAfter = _dateAfter.add(Duration(days: 1));
    }

    i = 1;
    while (widget.event.value!.start.isBefore(_dateBefore)) {
      _dateBefore = _dateBefore.subtract(Duration(days: 1));
      final layoutBox = widget.getLayoutBox(_dateBefore)!;
      final layoutPosition =
      layoutBox.localToGlobal(Offset.zero, ancestor: timelineBox);
      result.add(Rect.fromLTWH(
        layoutPosition.dx,
        bounds.top + 24 * i * _hourExtent,
        bounds.width,
        bounds.height,
      ));
      i++;
    }

    return result;
  }

  Widget _floatingEventBuilder(BuildContext context) {
    List<Rect> _rects = [];
    DateTime? date = _getTargetDayAt(_pointerLocation);
    if (mounted && date != null && widget.event.value != null) {
      _rects = _rectForDay(_eventBounds.value, date);
    }

    return ValueListenableBuilder(
        valueListenable: _eventBounds,
        builder: (context, rect, child) {
          // List<Rect> _rects = [];
          // DateTime? date = _getTargetDayAt(_pointerLocation);
          // if (mounted && date != null && widget.event.value != null) {
          //   _rects = _rectForDay(rect, date);
          // }

          return Stack(
            children: [
              // if (widget.viewType == CalendarView.days)
              Positioned.fromRect(
                rect: rect,
                child: child!,
              ),
              if (widget.viewType == CalendarView.week)
                for (Rect _rect in _rects)
                  Positioned.fromRect(
                    rect: _rect,
                    child: child!,
                  )
            ],
          );
        },
        child: CompositedTransformTarget(
          link: _layerLink,
          child: RenderIdProvider(
            id: Constants.elevatedEventId,
            child: _elevatedEventView(),
          ),
        ),
      );
  }

  Widget _sizerBuilder(BuildContext context) => ValueListenableBuilder(
        valueListenable: _animation,
        builder: (context, scale, child) {
          final theme = _draggableEventTheme.sizerTheme;

          return Positioned(
            width: theme.size.width * scale + theme.extraSpace * 2,
            height: theme.size.height * scale + theme.extraSpace * 2,
            child: child!,
          );
        },
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.center,
          child: RenderIdProvider(
            id: Constants.sizerId,
            child: _sizerView(),
          ),
        ),
      );
}
