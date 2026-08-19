/// Переписка — порт `fragment_chat_window.xml` + `ChatWindowFragment`.
///
/// Тот же экран работает и как чат с моделью ([SbChatWindowScreen.ai]) — в
/// Kotlin это тоже один фрагмент с флагом `isAiChat`: пузыри, просмотр фото и
/// меню сообщения там нужны те же, а расходятся шапка, отправка и опрос сети.
///
/// Отложено: открытие PDF (читалка — #9).
library;

import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart' show ImageSource;

import '../../data/auth_repository.dart';
import '../../data/book_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/gemini.dart';
import '../../data/push.dart';
import '../../data/swap_repository.dart';
import '../../design/avatar.dart';
import '../../design/liquid_glass.dart';
import '../../design/markdown.dart';
import '../../design/metrics.dart';
import '../../design/sheets.dart';
import '../../design/snack.dart';
import '../../design/tokens.dart';
import '../../design/typography.dart' as type;
import '../../model/chat_format.dart';
import '../../model/languages.dart';
import '../../model/models.dart';
import '../add/cover_pick.dart' show sbPickCoverJpeg;
import '../books/swap_flow.dart';
import '../reader/pdf_reader_screen.dart';

/// Порт `formatAiError`: код (или характерный обрывок текста сервера) — в
/// строку для человека. Незнакомое сообщение показываем как есть.
String sbAiErrorText(String raw) {
  final String s = raw.toLowerCase();
  if (raw == SbAiError.quota ||
      s.contains('quota') ||
      s.contains('resource_exhausted')) {
    return sbStrings.aiErrorQuota;
  }
  if (raw == SbAiError.key || s.contains('api key')) {
    return sbStrings.aiErrorKey;
  }
  if (raw == SbAiError.session ||
      s.contains('invalid credentials') ||
      s.contains('jwt')) {
    return sbStrings.aiErrorSession;
  }
  if (raw == SbAiError.generic ||
      s.contains('not found') ||
      s.contains('not deployed') ||
      s.contains('not supported')) {
    return sbStrings.aiErrorGeneric;
  }
  return raw;
}

class SbChatWindowScreen extends StatefulWidget {
  const SbChatWindowScreen({
    super.key,
    required this.chat,
    required this.auth,
    required this.books,
    required this.swaps,
    required this.roomId,
    required this.partnerId,
    required this.partnerName,
    this.ai = false,
  });

  final SbChatRepository chat;
  final SbAuthRepository auth;

  /// Нужны переходу в профиль собеседника: там его книги и заявка на обмен.
  final SbBookRepository books;
  final SbSwapRepository swaps;

  final String roomId;
  final String partnerId;
  final String partnerName;

  /// Чат с моделью: комната локальная, сети и собеседника нет.
  final bool ai;

  @override
  State<SbChatWindowScreen> createState() => _SbChatWindowScreenState();
}

/// Чат с моделью из списка диалогов и из карточки книги.
Future<void> sbOpenAiChat(
  BuildContext context, {
  required SbChatRepository chats,
  required SbAuthRepository auth,
  required SbBookRepository books,
  required SbSwapRepository swaps,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (BuildContext _) => SbChatWindowScreen(
      chat: chats,
      auth: auth,
      books: books,
      swaps: swaps,
      roomId: chats.aiRoomId,
      partnerId: sbAiPartnerId,
      partnerName: sbAiChatName,
      ai: true,
    ),
  ),
);

/// Открыть переписку, зная только комнату: у уведомления и его истории есть
/// лишь `room_id`, собеседника спрашиваем у сервера.
Future<void> sbOpenRoomById(
  BuildContext context, {
  required SbChatRepository chats,
  required SbAuthRepository auth,
  required SbBookRepository books,
  required SbSwapRepository swaps,
  required String roomId,
  String partnerName = '',
}) async {
  final String partnerId = await chats.partnerIdForRoom(roomId) ?? '';
  if (partnerId.isEmpty) return;
  // Имя из уведомления — то же, что было в заголовке: лишний запрос профиля не
  // нужен, но если его нет (тап по пушу с сервера), спрашиваем.
  String name = partnerName.trim();
  if (name.isEmpty) {
    name = ((await auth.profileById(partnerId))?.name ?? '').trim();
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => SbChatWindowScreen(
        chat: chats,
        auth: auth,
        books: books,
        swaps: swaps,
        roomId: roomId,
        partnerId: partnerId,
        partnerName: name.isEmpty ? sbStrings.classmate : name,
      ),
    ),
  );
}

/// Пункт меню сообщения. Меню собирается по месту (что можно с этим пузырём),
/// поэтому индекс из шторки сам по себе ничего не значит.
class _Act {
  const _Act(this.label, this.run, {this.destructive = false});

  final String label;
  final Future<void> Function() run;
  final bool destructive;
}

class _SbChatWindowScreenState extends State<SbChatWindowScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Ключи пузырей — по ним прокрутка к сообщению, на которое ответили.
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  /// Шапка и нижняя группа (ответ, вложение, ввод) лежат поверх списка: сообщения
  /// проезжают под стеклом, иначе размывать ему нечего. Их высота заранее
  /// неизвестна — крупный шрифт системы, поле на пять строк, полоса ответа, —
  /// поэтому меряем после кадра и с этого отступа начинается список. Тот же
  /// приём, что у шапок каталога и списка диалогов.
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _bottomKey = GlobalKey();
  double _headerHeight = 96;
  double _bottomHeight = 72;

  StreamSubscription<List<SbMessage>>? _sub;
  Timer? _delta;
  Timer? _presence;
  DateTime _typingSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<SbMessage> _msgs = const <SbMessage>[];
  int _limit = SbChatRepository.pageSize;
  bool _hasMore = true;
  bool _loadingOlder = false;
  SbProfile? _partner;
  bool _partnerTyping = false;
  String? _highlight;
  SbMessage? _replyTo;

  /// Выбранное фото ждёт подписи в поле ввода — порт `pendingAttachment`.
  Uint8List? _pending;

  /// Тип ожидающего файла: у модели фото и видео уезжают одной кнопкой.
  String _pendingMime = 'image/jpeg';
  bool _uploading = false;
  int _tick = 0;

  /// Пока модель отвечает, ввод заперт, а кнопка отправки становится стопом.
  /// Отменять корутину, как в Kotlin, здесь нечего — вместо этого счётчик
  /// поколений: сменился номер, значит начатый ответ уже никому не нужен.
  bool _aiTyping = false;
  String? _aiStream;
  int _aiRun = 0;

  bool get _aiBusy => _aiTyping || _aiStream != null;

  String get _myId => widget.auth.session.currentUserId ?? '';

  @override
  void initState() {
    super.initState();
    // Об открытой комнате не уведомляем: человек её и читает.
    if (!widget.ai) sbActiveRoomId = widget.roomId;
    _subscribe();
    _scroll.addListener(_onScroll);
    _boot().ignore();
    // У переписки с моделью нет серверной половины: ни дельты, ни «печатает».
    if (widget.ai) return;
    _delta = Timer.periodic(
      const Duration(milliseconds: 1500),
      (Timer _) => _pollNew().ignore(),
    );
    _presence = Timer.periodic(
      const Duration(seconds: 2),
      (Timer _) => _pollPresence().ignore(),
    );
  }

  @override
  void dispose() {
    if (sbActiveRoomId == widget.roomId) sbActiveRoomId = null;
    _delta?.cancel();
    _presence?.cancel();
    _sub?.cancel().ignore();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Окно кэша растёт страницами, поэтому подписка пересоздаётся.
  void _subscribe() {
    _sub?.cancel().ignore();
    _sub =
        (widget.ai
                ? widget.chat.watchAiMessages(_limit)
                : widget.chat.watchMessages(widget.roomId, _limit))
            .listen((List<SbMessage> list) {
              if (!mounted) return;
              setState(() => _msgs = list);
            });
  }

  Future<void> _boot() async {
    if (widget.ai) {
      await widget.chat.cleanupLegacyAiChat();
      return;
    }
    await widget.chat.fetchLatestMessages(widget.roomId);
    await _markRead();
    widget.chat.updateMyLastSeen().ignore();
    final SbProfile? p = await widget.auth.profileById(widget.partnerId);
    if (!mounted || p == null) return;
    setState(() => _partner = p);
  }

  /// Прочитано. Заодно помечаем последнее чужое сообщение показанным: поллер
  /// входящих иначе уведомит о том, что уже открыто на экране.
  Future<void> _markRead() async {
    final String? last = await widget.chat.markRoomRead(widget.roomId);
    await sbMarkIncomingSeen(widget.auth.session, widget.roomId, last);
  }

  Future<void> _pollNew() async {
    final int n = await widget.chat.fetchNewMessages(widget.roomId);
    if (n <= 0 || !mounted) return;
    // Комната открыта — пришедшее уже прочитано, счётчик в списке обнуляем.
    await _markRead();
    _stickToBottom();
  }

  Future<void> _pollPresence() async {
    final bool typing = await widget.chat.isPartnerTyping(
      widget.roomId,
      widget.partnerId,
    );
    // Профиль тянем впятеро реже: «был в сети» меняется минутами.
    final SbProfile? p = (_tick++ % 5 == 0)
        ? await widget.auth.profileById(widget.partnerId)
        : null;
    if (!mounted) return;
    setState(() {
      _partnerTyping = typing;
      if (p != null) _partner = p;
    });
  }

  /// Список перевёрнут, поэтому «низ» — это нулевое смещение. Если человек
  /// ушёл читать историю, новое сообщение его не выдёргивает.
  void _stickToBottom() {
    if (!_scroll.hasClients || _scroll.position.pixels > 240) return;
    _scroll
        .animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        )
        .ignore();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Верх перевёрнутого списка — максимум смещения: там догружается история.
    final ScrollPosition p = _scroll.position;
    if (p.pixels < p.maxScrollExtent - 120) return;
    _loadOlder().ignore();
  }

  Future<void> _loadOlder() async {
    // У модели истории на сервере нет — докручивать некуда.
    if (widget.ai || _loadingOlder || !_hasMore) return;
    _loadingOlder = true;
    final int n = await widget.chat.fetchOlderMessages(widget.roomId);
    if (mounted) {
      setState(() {
        _limit += SbChatRepository.pageSize;
        // Ноль строк с сервера — старее ничего нет, дальше не дёргаем сеть.
        _hasMore = n > 0;
      });
      _subscribe();
    }
    _loadingOlder = false;
  }

  /// Сигнал «печатаю» не чаще раза в две секунды — как в Kotlin.
  void _signalTyping() {
    if (widget.ai) return;
    final DateTime now = DateTime.now();
    if (now.difference(_typingSentAt) < const Duration(seconds: 2)) return;
    _typingSentAt = now;
    widget.chat.heartbeatTyping(widget.roomId).ignore();
  }

  Future<void> _send() async {
    if (widget.ai) {
      await _sendAi();
      return;
    }
    final Uint8List? photo = _pending;
    final String text = _input.text.trim();
    if (photo == null && text.isEmpty) return;
    if (photo != null) {
      // Картинка уезжает с подписью из того же поля, что и текст — как в Kotlin
      // `sendPendingAttachment`. Ответ на сообщение вложение не носит.
      _input.clear();
      setState(() {
        _pending = null;
        _replyTo = null;
        _uploading = true;
      });
      final String? err = await widget.chat.sendImage(
        widget.roomId,
        photo,
        caption: text,
      );
      if (!mounted) return;
      setState(() => _uploading = false);
      if (err != null) sbSnackError(context, err);
      _stickToBottom();
      return;
    }
    final SbMessage? target = _replyTo;
    final String content = target == null
        ? text
        : sbReplyContent(
            target.id,
            target.senderName,
            sbAttachmentPreview(target.content),
            text,
          );
    _input.clear();
    setState(() => _replyTo = null);
    final String? err = await widget.chat.sendMessage(widget.roomId, content);
    if (!mounted) return;
    if (err != null) sbSnackError(context, err);
    _stickToBottom();
  }

  /// Порт `showMessageOptions`: набор пунктов зависит от того, что за пузырь и
  /// чей он. Вместо привязанного к пузырю `IosActionMenu` — обычная шторка.
  Future<void> _options(SbMessage m) async {
    final SbChatKind kind = sbParseAttachment(m.content);
    final bool mine =
        _myId.isNotEmpty && m.senderId.toLowerCase() == _myId.toLowerCase();
    final String body = sbAttachmentBody(m.content).trim();
    final List<_Act> acts = <_Act>[
      // Ответы модель не понимает, а править её реплику нечестно: у неё нет
      // серверной копии, и после правки история перестанет совпадать с ответом.
      if (!widget.ai) _Act(sbStrings.replyMessage, () async => _startReply(m)),
      if (kind is SbChatImage)
        _Act(sbStrings.viewPhoto, () async => _viewPhoto(kind.url)),
      if ((kind is SbChatText || kind is SbChatReply) && body.isNotEmpty)
        _Act(sbStrings.copyMessage, () => _copy(body)),
      // Править можно только обычный текст: у вложения правится не то, что видно.
      if (mine && !widget.ai && kind is SbChatText)
        _Act(sbStrings.editMessage, () => _edit(m)),
      // В переписке с моделью удаляется любой пузырь: он живёт только в кэше.
      if (mine || widget.ai)
        _Act(sbStrings.deleteMessage, () => _delete(m), destructive: true),
    ];
    final int? pick = await sbShowPickerSheet(
      context,
      title: sbStrings.messageOptions,
      options: <SbPickerOption>[
        for (final _Act a in acts)
          SbPickerOption(a.label, destructive: a.destructive),
      ],
    );
    if (pick == null || !mounted) return;
    await acts[pick].run();
  }

  void _startReply(SbMessage m) => setState(() => _replyTo = m);

  // --- чат с моделью (порт AI-половины ChatWindowFragment) ---

  /// Порт `sendAiAfterUserSave`: пока идёт ответ, эта же кнопка — стоп.
  Future<void> _sendAi() async {
    if (_aiBusy) {
      await _stopAi();
      return;
    }
    final Uint8List? file = _pending;
    final String text = _input.text.trim();
    if (file == null && text.isEmpty) return;
    final String mime = _pendingMime;
    _input.clear();
    setState(() {
      _pending = null;
      _replyTo = null;
    });
    await _askAi(() async {
      if (file == null) return widget.chat.saveAiUserMessage(text);
      return mime.startsWith('video/')
          ? widget.chat.saveAiUserVideo(file, mime: mime, caption: text)
          : widget.chat.saveAiUserImage(file, mime: mime, caption: text);
    });
  }

  /// Реплика человека сначала ложится в кэш (у переспроса сохранять нечего —
  /// там `saveUser` ничего не делает), потом идёт запрос, потом ответ
  /// проявляется по символу. После каждого `await` проверяется поколение:
  /// нажали стоп — дальше рисовать нечего.
  Future<void> _askAi(Future<String?> Function() saveUser) async {
    final int run = ++_aiRun;
    setState(() => _aiTyping = true);
    final String? saveErr = await saveUser();
    if (!mounted || run != _aiRun) return;
    if (saveErr != null) {
      setState(() => _aiTyping = false);
      sbSnackError(context, saveErr);
      return;
    }
    _stickToBottom();
    final String reply;
    try {
      reply = await widget.chat.requestAiReply();
    } catch (e) {
      if (!mounted || run != _aiRun) return;
      setState(() => _aiTyping = false);
      sbSnackError(
        context,
        sbAiErrorText(e is SbAiException ? e.code : SbAiError.generic),
      );
      return;
    }
    if (!mounted || run != _aiRun) return;
    setState(() {
      _aiTyping = false;
      _aiStream = '';
    });
    for (int i = 0; i < reply.length; i++) {
      // На знаке препинания пауза длиннее — так текст читается, а не мелькает.
      await Future<void>.delayed(
        Duration(milliseconds: '\n.!?'.contains(reply[i]) ? 28 : 14),
      );
      if (!mounted || run != _aiRun) return;
      setState(() => _aiStream = reply.substring(0, i + 1));
    }
    await widget.chat.saveAiAssistantMessage(reply);
    if (!mounted || run != _aiRun) return;
    setState(() => _aiStream = null);
    _stickToBottom();
  }

  /// Стоп — порт `stopAiGeneration`: недописанный ответ остаётся в переписке,
  /// иначе пропадёт и то, что человек успел прочитать.
  Future<void> _stopAi() async {
    final String partial = (_aiStream ?? '').trim();
    _aiRun++;
    setState(() {
      _aiTyping = false;
      _aiStream = null;
    });
    if (partial.isNotEmpty) await widget.chat.saveAiAssistantMessage(partial);
    if (mounted) sbSnack(context, sbStrings.aiStopped);
  }

  /// Переспросить — порт `regenerateAiAnswer`: старый ответ убирается из
  /// истории, иначе модель увидит его и повторит.
  Future<void> _regenerate(SbMessage m) async {
    if (_aiBusy) return;
    await widget.chat.deleteLocalMessage(m.id);
    if (!mounted) return;
    await _askAi(() async => null);
  }

  /// Вложения — порт `ChatAttachBottomSheet`. Сетки последних снимков из
  /// MediaStore здесь нет: она требует отдельной зависимости на галерею, а
  /// системный пикер показывает те же файлы.
  Future<void> _attach() async {
    final int? pick = await sbShowPickerSheet(
      context,
      title: sbStrings.send,
      options: <SbPickerOption>[
        SbPickerOption(sbStrings.photo),
        SbPickerOption(sbStrings.attachCamera),
        // Видео понимает только модель, документ — только человек.
        SbPickerOption(widget.ai ? sbStrings.video : sbStrings.attachPdfFile),
      ],
    );
    if (pick == null || !mounted) return;
    if (pick == 2) {
      await (widget.ai ? _attachVideo() : _attachPdf());
      return;
    }
    // 1600 px: пузырь шире обложки, но полный кадр с камеры в чат не нужен.
    final Uint8List? jpeg = await sbPickCoverJpeg(
      maxEdge: 1600,
      source: pick == 1 ? ImageSource.camera : ImageSource.gallery,
    );
    if (jpeg == null || !mounted) return;
    setState(() {
      _pending = jpeg;
      _pendingMime = 'image/jpeg';
    });
  }

  /// Видео уходит только модели и целиком внутри сообщения — отсюда предел в
  /// 15 МБ, как в Kotlin: base64 раздувает файл ещё на треть.
  Future<void> _attachVideo() async {
    final PlatformFile? file = await FilePicker.pickFile(type: FileType.video);
    if (file == null || !mounted) return;
    if (await file.length() > sbMaxAiVideoBytes) {
      if (mounted) sbSnackError(context, sbStrings.maxVideoSize);
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) sbSnackError(context, sbStrings.cannotReadFile);
      return;
    }
    if (!mounted) return;
    setState(() {
      _pending = bytes;
      _pendingMime = _videoMime(file.name);
    });
  }

  /// Документ уходит сразу, без подписи — как `pickPdf` в Kotlin. Размер
  /// смотрим по метаданным: 200-мегабайтный файл незачем читать в память.
  Future<void> _attachPdf() async {
    final PlatformFile? file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
    );
    if (file == null || !mounted) return;
    if (await file.length() > sbMaxPdfBytes) {
      if (mounted) sbSnackError(context, sbStrings.maxFileSize);
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (mounted) sbSnackError(context, sbStrings.cannotReadFile);
      return;
    }
    if (!mounted) return;
    setState(() => _uploading = true);
    final String? err = await widget.chat.sendPdf(
      widget.roomId,
      bytes,
      file.name,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (err != null) sbSnackError(context, err);
    _stickToBottom();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) sbSnack(context, sbStrings.messageCopied);
  }

  Future<void> _delete(SbMessage m) async {
    // У переписки с моделью серверной половины нет — удаляем из кэша.
    if (widget.ai) {
      await widget.chat.deleteLocalMessage(m.id);
      return;
    }
    final String? err = await widget.chat.deleteMessage(m.id, widget.roomId);
    if (!mounted || err == null) return;
    sbSnackError(context, err);
  }

  Future<void> _edit(SbMessage m) async {
    final String? text = await sbShowSheet<String>(
      context,
      background: SbColors.of(context).bgPrimary,
      topRadius: cornerExtraLarge,
      maxHeightFraction: 0.6,
      builder: (BuildContext _) =>
          _EditSheet(initial: sbAttachmentBody(m.content)),
    );
    if (text == null || !mounted) return;
    final String? err = await widget.chat.editMessage(
      m.id,
      widget.roomId,
      text,
    );
    if (!mounted || err == null) return;
    sbSnackError(context, err);
  }

  void _viewPhoto(String url) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext ctx) => Scaffold(
              backgroundColor: SbColors.of(ctx).chatSystemBar,
              appBar: AppBar(
                backgroundColor: SbColors.of(ctx).chatSystemBar,
                foregroundColor: SbColors.of(ctx).alwaysWhite,
              ),
              body: Center(
                child: InteractiveViewer(
                  child: _chatImage(SbColors.of(ctx), url),
                ),
              ),
            ),
          ),
        )
        .ignore();
  }

  /// Книга из переписки открывается той же читалкой, только без `bookId`:
  /// прогресс и выделения привязывать не к чему.
  void _openPdf(String url, String name) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext _) => SbPdfReaderScreen(
              books: widget.books,
              title: name,
              pdfUrl: url,
            ),
          ),
        )
        .ignore();
  }

  /// ponytail: прокрутка только к уже построенному пузырю — адресация по индексу
  /// требует `scrollable_positioned_list`; цель вне окна получает подсветку и
  /// найдётся, когда до неё домотают. Ставить зависимость — если попросят.
  void _jumpTo(String id) {
    setState(() => _highlight = id);
    final BuildContext? ctx = _keys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 220),
      ).ignore();
    }
    Timer(const Duration(milliseconds: 900), () {
      if (mounted && _highlight == id) setState(() => _highlight = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final SbColors c = SbColors.of(context);
    final SbMessage? reply = _replyTo;
    final Uint8List? photo = _pending;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _measure());
    return Scaffold(
      backgroundColor: c.chatBg,
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: _list(c)),
          Positioned(left: 0, right: 0, top: 0, child: _header(c)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SbGlassBar(
              key: _bottomKey,
              tint: c.chatInputGlassTint,
              hairline: c.chatInputHairline,
              bottomEdge: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (reply != null) _replyBar(c, reply),
                  if (photo != null) _pendingBar(c, photo),
                  _inputBar(c),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Высота стеклянных панелей — списку она нужна отступом.
  void _measure() {
    final double header = _sizeOf(_headerKey) ?? _headerHeight;
    final double bottom = _sizeOf(_bottomKey) ?? _bottomHeight;
    if ((header - _headerHeight).abs() < 0.5 &&
        (bottom - _bottomHeight).abs() < 0.5) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _headerHeight = header;
      _bottomHeight = bottom;
    });
  }

  double? _sizeOf(GlobalKey key) {
    final RenderBox? box =
        key.currentContext?.findRenderObject() as RenderBox?;
    final double h = box?.size.height ?? 0;
    return h > 0 ? h : null;
  }

  /// Шапка: имя, статус, аватар. Профиль собеседника — задача #7.
  Widget _header(SbColors c) {
    final SbProfile? p = _partner;
    final ({String text, bool live})? presence = widget.ai
        ? (_aiBusy ? (text: sbStrings.statusTyping, live: true) : null)
        : sbPresenceText(p?.lastSeen, _partnerTyping);
    final String handle = (p?.username ?? '').trim();
    final String name = widget.ai
        ? sbAiChatName
        : ((p?.name ?? '').trim().isEmpty ? widget.partnerName : p!.name);
    final String sub = widget.ai
        ? (presence?.text ?? sbStrings.aiStatus)
        : (presence?.text ??
              (handle.isEmpty ? sbStrings.tapToViewProfile : '@$handle'));
    return SbGlassBar(
      key: _headerKey,
      tint: c.navGlassTint,
      hairline: c.chatInputHairline,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(spaceXs, spaceS, spaceM, spaceS),
          child: Row(
            children: <Widget>[
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new, size: 20, color: c.brand),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              if (widget.ai)
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.aiCardStart,
                    shape: BoxShape.circle,
                  ),
                  child: const Text('✨', style: TextStyle(fontSize: 18)),
                )
              else
                SbAvatar(
                  size: 40,
                  initials: (p?.initials ?? '').isEmpty
                      ? sbInitials(name)
                      : p!.initials,
                  colorHex: p?.avatarColorHex ?? '#2563EB',
                  url: p?.avatarUrl ?? '',
                  fontSize: 15,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: (widget.ai || widget.partnerId.isEmpty)
                      // Поддержка и модель — не люди с профилем, открывать нечего.
                      ? null
                      : () => sbOpenUserProfile(
                          context,
                          userId: widget.partnerId,
                          books: widget.books,
                          auth: widget.auth,
                          chats: widget.chat,
                          swaps: widget.swaps,
                          // Комната — доказательство обмена для оценки.
                          roomId: widget.roomId,
                        ).ignore(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: c.textPrimary,
                              ),
                            ),
                          ),
                          if ((p?.teamBadge ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: SbTeamBadge(badge: p!.teamBadge, size: 15),
                            ),
                        ],
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: (presence?.live ?? false)
                              ? c.brand
                              : c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(SbColors c) {
    // Пока модель думает, внизу списка висит отдельный пузырь: он ещё не в кэше.
    final bool tail = widget.ai && _aiBusy;
    if (_msgs.isEmpty && !tail) {
      return Center(
        child: Text(
          widget.ai ? sbStrings.askAiAnything : sbStrings.tapToChat,
          style: TextStyle(fontSize: 15, color: c.textSecondary),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      // Список лежит под стеклянными панелями, поэтому отступы — их измеренные
      // высоты: сообщения проезжают под шапкой и панелью ввода, а не упираются
      // в них.
      padding: EdgeInsets.only(
        left: spaceM,
        right: spaceM,
        top: _headerHeight + spaceS,
        bottom: _bottomHeight + spaceS,
      ),
      itemCount: _msgs.length + (tail ? 1 : 0),
      itemBuilder: (BuildContext ctx, int i) {
        if (tail && i == 0) return _aiPending(c);
        // Перевёрнутый список идёт от конца: последнее сообщение — снизу.
        final int index = _msgs.length - 1 - (tail ? i - 1 : i);
        final SbMessage m = _msgs[index];
        final bool mine =
            _myId.isNotEmpty && m.senderId.toLowerCase() == _myId.toLowerCase();
        final Widget bubble = _Bubble(
          key: _keys.putIfAbsent(m.id, GlobalKey.new),
          message: m,
          all: _msgs,
          mine: mine,
          // Подряд идущие свои реплики собираются в группу, как в iMessage:
          // ближе друг к другу и с поджатыми внутренними углами.
          groupHead: !_sameRun(index - 1, m),
          groupTail: !_sameRun(index + 1, m),
          highlighted: _highlight == m.id,
          onLongPress: () => _options(m).ignore(),
          onQuoteTap: _jumpTo,
          onPhoto: _viewPhoto,
          onPdf: _openPdf,
          onRetry: () => _retry(m),
          onCopy: widget.ai ? (String text) => _copy(text).ignore() : null,
          onRegenerate: widget.ai ? () => _regenerate(m).ignore() : null,
        );
        // Ответить модели нельзя — смахивание в её чате ничего не даёт.
        return widget.ai ? bubble : _swipeToReply(m, bubble);
      },
    );
  }

  /// Сообщение под индексом [i] — из той же серии, что [m]: тот же автор и не
  /// больше пяти минут разницы. Разрыв во времени начинает новую группу, иначе
  /// вчерашняя реплика склеилась бы с сегодняшней.
  bool _sameRun(int i, SbMessage m) {
    if (i < 0 || i >= _msgs.length) return false;
    final SbMessage other = _msgs[i];
    if (other.senderId != m.senderId || other.isAi != m.isAi) return false;
    final DateTime? a = sbParseIso(other.createdAt);
    final DateTime? b = sbParseIso(m.createdAt);
    if (a == null || b == null) return true;
    return a.difference(b).abs() <= const Duration(minutes: 5);
  }

  /// Ответ, который ещё печатается: сначала «thinking…», потом сам текст.
  Widget _aiPending(SbColors c) {
    final String text = _aiStream ?? '';
    final TextStyle style = TextStyle(fontSize: 16, color: c.chatTextAi);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.92,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.chatBubbleAi,
          borderRadius: BorderRadius.circular(cornerMedium),
        ),
        child: Text.rich(
          text.isEmpty
              ? TextSpan(text: 'thinking…', style: style)
              : sbMarkdown(text, style),
        ),
      ),
    );
  }

  Future<void> _retry(SbMessage m) async {
    final String? err = await widget.chat.retryMessage(m.id);
    if (!mounted || err == null) return;
    sbSnackError(context, err);
  }

  /// Смахивание вправо — ответ. `confirmDismiss` возвращает false: пузырь
  /// должен вернуться на место, а не исчезнуть.
  Widget _swipeToReply(SbMessage m, Widget child) => Dismissible(
    key: ValueKey<String>('swipe-${m.id}'),
    direction: DismissDirection.startToEnd,
    dismissThresholds: const <DismissDirection, double>{
      DismissDirection.startToEnd: 0.3,
    },
    background: Align(
      alignment: Alignment.centerLeft,
      child: Icon(Icons.reply, size: 20, color: SbColors.of(context).brand),
    ),
    confirmDismiss: (DismissDirection _) async {
      _startReply(m);
      return false;
    },
    child: child,
  );

  Widget _replyBar(SbColors c, SbMessage m) => DecoratedBox(
    // Фон общий у всей нижней группы; здесь только черта до поля ввода.
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: c.chatInputHairline, width: sbHairline),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(spaceM, spaceS, spaceS, spaceS),
      child: Row(
        children: <Widget>[
          Container(width: 3, height: 32, color: c.brand),
          const SizedBox(width: spaceS),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  sbStrings.replyingTo(m.senderName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: c.brand,
                  ),
                ),
                Text(
                  sbAttachmentPreview(m.content),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: c.textTertiary),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    ),
  );

  /// Полоса выбранного файла: превью, подсказка про подпись и крестик. У видео
  /// кадра нет — вместо него плашка с иконкой.
  Widget _pendingBar(SbColors c, Uint8List photo) {
    final bool video = _pendingMime.startsWith('video/');
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.chatInputHairline, width: sbHairline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(spaceM, spaceS, spaceXs, spaceS),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(cornerExtraSmall),
              child: video
                  ? Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      color: c.chatImagePlaceholder,
                      child: Icon(
                        Icons.movie_outlined,
                        size: 20,
                        color: c.textSecondary,
                      ),
                    )
                  : Image.memory(
                      photo,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      cacheWidth: 132,
                    ),
            ),
            const SizedBox(width: spaceS),
            Expanded(
              child: Text(
                video ? sbStrings.attachReadyVideo : sbStrings.attachReadyPhoto,
                maxLines: 2,
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 20, color: c.textTertiary),
              onPressed: () => setState(() => _pending = null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputBar(SbColors c) {
    final OutlineInputBorder frame = OutlineInputBorder(
      borderRadius: BorderRadius.circular(22),
      borderSide: BorderSide.none,
    );
    // Фон и волосок сверху — у стекла, которое несёт всю нижнюю группу.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(spaceXs, spaceS, spaceS, spaceS),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            IconButton(
              icon: Icon(Icons.add_circle_outline, size: 24, color: c.brand),
              onPressed: (_uploading || _aiBusy)
                  ? null
                  : () => _attach().ignore(),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                onChanged: (String _) => _signalTyping(),
                enabled: !_aiBusy,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(fontSize: 16, color: c.textPrimary),
                cursorColor: c.brand,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: c.chatInputFieldBg,
                  hintText: widget.ai
                      ? sbStrings.askAnythingHint
                      : sbStrings.typeMessage,
                  hintStyle: TextStyle(fontSize: 16, color: c.textTertiary),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: frame,
                  enabledBorder: frame,
                  focusedBorder: frame,
                ),
              ),
            ),
            const SizedBox(width: spaceS),
            InkWell(
              onTap: _uploading ? null : () => _send().ignore(),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.brand,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  // Пока модель отвечает, та же кнопка останавливает ответ.
                  _aiBusy ? Icons.stop_rounded : Icons.arrow_upward,
                  size: 20,
                  color: c.alwaysWhite,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Видео для модели — как в Kotlin, не больше 15 МБ: файл уезжает base64-строкой
/// внутри запроса, и раздувается при этом на треть.
const int sbMaxAiVideoBytes = 15 * 1024 * 1024;

/// Тип по расширению: у пикера его нет, а без mime Gemini файл не примет.
String _videoMime(String name) => switch (name.toLowerCase().split('.').last) {
  'mov' => 'video/quicktime',
  'webm' => 'video/webm',
  '3gp' => 'video/3gpp',
  'mkv' => 'video/x-matroska',
  _ => 'video/mp4',
};

/// Картинка пузыря: ссылка из storage или `data:`-URI (картинка нейросети).
Widget _chatImage(SbColors c, String url) {
  final Widget stub = Container(height: 180, color: c.chatImagePlaceholder);
  if (url.startsWith('data:')) {
    try {
      return Image.memory(
        base64Decode(url.split(',').last),
        fit: BoxFit.cover,
        errorBuilder: (BuildContext ctx, Object err, StackTrace? st) => stub,
      );
    } catch (_) {
      // Битый base64 — не повод падать на отрисовке переписки.
      return stub;
    }
  }
  return CachedNetworkImage(
    imageUrl: url,
    fit: BoxFit.cover,
    placeholder: (BuildContext ctx, String u) => stub,
    errorWidget: (BuildContext ctx, String u, Object err) => stub,
  );
}

/// Правка сообщения — шторка вместо диалога (диалоги в проекте запрещены).
class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.initial});

  final String initial;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SbColors c = SbColors.of(context);
    return Padding(
      // Клавиатура не должна прятать поле ввода.
      padding: EdgeInsets.only(
        left: spaceL,
        right: spaceL,
        top: spaceM,
        bottom: MediaQuery.viewInsetsOf(context).bottom + spaceL,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Center(child: SbSheetHandle()),
          Text(
            sbStrings.editMessage,
            style: type.sheetTitle.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: spaceM),
          TextField(
            controller: _ctl,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            style: TextStyle(fontSize: 16, color: c.textPrimary),
            cursorColor: c.brand,
            decoration: InputDecoration(
              filled: true,
              fillColor: c.chatInputFieldBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(cornerMedium),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: spaceM),
          Row(
            children: <Widget>[
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    sbStrings.cancel,
                    style: TextStyle(color: c.textSecondary),
                  ),
                ),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final String text = _ctl.text.trim();
                    if (text.isEmpty) return;
                    Navigator.of(context).pop(text);
                  },
                  child: Text(sbStrings.save),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Пузырь — порт `MessageAdapter.bind`. Ответ нейросети шире (0.92 экрана),
/// свои и чужие сообщения жмутся по содержимому.
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.all,
    required this.mine,
    required this.groupHead,
    required this.groupTail,
    required this.highlighted,
    required this.onLongPress,
    required this.onQuoteTap,
    required this.onPhoto,
    required this.onPdf,
    required this.onRetry,
    this.onCopy,
    this.onRegenerate,
  });

  final SbMessage message;

  /// Вся загруженная переписка — по ней ищется цель ответа.
  final List<SbMessage> all;
  final bool mine;

  /// Первый и последний пузырь серии подряд идущих реплик одного автора.
  final bool groupHead;
  final bool groupTail;
  final bool highlighted;
  final VoidCallback onLongPress;
  final void Function(String targetId) onQuoteTap;
  final void Function(String url) onPhoto;
  final void Function(String url, String name) onPdf;
  final VoidCallback onRetry;

  /// Только в чате с моделью: ряд кнопок под её ответом.
  final void Function(String text)? onCopy;
  final VoidCallback? onRegenerate;

  /// Углы серии: со стороны автора внутренние углы поджаты, и группа читается
  /// одним блоком, а не лестницей отдельных пузырей.
  static const double _grouped = 6;

  BorderRadius get _shape {
    const Radius full = Radius.circular(cornerMedium);
    const Radius tight = Radius.circular(_grouped);
    final Radius near = groupHead ? full : tight;
    final Radius far = groupTail ? full : tight;
    return mine
        ? BorderRadius.only(
            topLeft: full,
            bottomLeft: full,
            topRight: near,
            bottomRight: far,
          )
        : BorderRadius.only(
            topRight: full,
            bottomRight: full,
            topLeft: near,
            bottomLeft: far,
          );
  }

  @override
  Widget build(BuildContext context) {
    final SbColors c = SbColors.of(context);
    final bool ai = message.isAi;
    final Color bg = ai
        ? c.chatBubbleAi
        : (mine ? c.chatBubbleMe : c.chatBubbleThem);
    final Color fg = ai ? c.chatTextAi : (mine ? c.chatTextMe : c.chatTextThem);
    final Color meta = (mine && !ai) ? c.chatMetaMe : c.chatMetaThem;
    final SbChatKind kind = sbParseAttachment(message.content);
    final bool bare = kind is SbChatImage && kind.caption.trim().isEmpty;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        // Внутри серии пузыри почти вплотную, между сериями — дыхание.
        padding: EdgeInsets.only(top: groupHead ? 5 : 1, bottom: 1),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Opacity(
            opacity: message.sendState == SbSendState.sending ? 0.6 : 1,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * (ai ? 0.92 : 0.78),
              ),
              // Вложение без подписи занимает пузырь целиком, без отбивки.
              padding: bare
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: _shape,
                border: highlighted
                    ? Border.all(color: c.brand, width: 2)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ..._content(c, kind, fg, meta),
                  if (ai && onRegenerate != null) _aiActions(meta),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(SbColors c, SbChatKind kind, Color fg, Color meta) =>
      switch (kind) {
        SbChatImage k => <Widget>[
          _photo(c, k.url, k.caption.trim().isEmpty),
          if (k.caption.trim().isNotEmpty) _line(c, k.caption, fg, meta),
        ],
        SbChatVideo k => <Widget>[
          // Плеера нет и в Kotlin: видео присылает только нейросеть (#8).
          _line(
            c,
            k.caption.trim().isEmpty
                ? '🎬 ${sbStrings.video}'
                : '🎬 ${k.caption}',
            fg,
            meta,
          ),
        ],
        SbChatPdf k => <Widget>[
          _line(c, '📄 ${k.name}', fg, meta, onTap: () => onPdf(k.url, k.name)),
        ],
        SbChatReply k => <Widget>[_quote(c, k, fg), _line(c, k.body, fg, meta)],
        SbChatText k => <Widget>[_line(c, k.text, fg, meta)],
      };

  /// Копировать и переспросить — порт ряда кнопок под готовым ответом модели.
  Widget _aiActions(Color meta) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _aiAction(
          Icons.copy_rounded,
          sbStrings.copyMessage,
          meta,
          () => onCopy?.call(sbAttachmentBody(message.content).trim()),
        ),
        const SizedBox(width: spaceM),
        _aiAction(
          Icons.refresh_rounded,
          sbStrings.aiRegenerate,
          meta,
          onRegenerate!,
        ),
      ],
    ),
  );

  Widget _aiAction(
    IconData icon,
    String label,
    Color color,
    VoidCallback tap,
  ) => GestureDetector(
    onTap: tap,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    ),
  );

  /// Текст и время в одной строке: пузырь жмётся по содержимому, время садится
  /// справа снизу — как в Kotlin-разметке. Ответ модели размечен Markdown.
  Widget _line(
    SbColors c,
    String body,
    Color fg,
    Color meta, {
    VoidCallback? onTap,
  }) {
    final TextStyle style = TextStyle(fontSize: 16, color: fg);
    final Widget text = message.isAi
        ? Text.rich(sbMarkdown(body, style))
        : Text(body, style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Flexible(
          child: onTap == null
              ? text
              : GestureDetector(onTap: onTap, child: text),
        ),
        const SizedBox(width: 6),
        _meta(c, meta),
      ],
    );
  }

  /// Над фото время всегда белое: `chat_meta_me` в тёмной теме почти чёрный и
  /// на снимке не читается.
  Widget _photo(SbColors c, String url, bool overlayMeta) => ClipRRect(
    borderRadius: BorderRadius.circular(cornerMedium),
    child: Stack(
      children: <Widget>[
        GestureDetector(onTap: () => onPhoto(url), child: _chatImage(c, url)),
        if (overlayMeta)
          Positioned(right: 8, bottom: 6, child: _meta(c, c.alwaysWhite)),
      ],
    ),
  );

  Widget _meta(SbColors c, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 1),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          sbFormatTime(message.createdAt),
          style: TextStyle(fontSize: 11, color: color),
        ),
        // Галочки — только у своих сообщений: чужой статус мы не знаем.
        if (mine)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: switch (message.sendState) {
              SbSendState.sending => Text(
                '🕗',
                style: TextStyle(fontSize: 10, color: color),
              ),
              SbSendState.failed => GestureDetector(
                onTap: onRetry,
                child: Text(
                  '!',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: c.errorRed,
                  ),
                ),
              ),
              SbSendState.sent => Text(
                '✓✓',
                style: TextStyle(fontSize: 11, color: color),
              ),
            },
          ),
      ],
    ),
  );

  /// Цитата. Тап ведёт к исходному сообщению — если его удалось найти: у ответов
  /// из старой версии в маркере нет id, и цель ищется по автору и превью.
  Widget _quote(SbColors c, SbChatReply k, Color fg) {
    final bool own = mine && !message.isAi;
    final Color accent = own ? c.chatReplyAccentMe : c.chatReplyAccentThem;
    return GestureDetector(
      onTap: () {
        final String? id = sbResolveReplyTarget(k, all);
        if (id != null) onQuoteTap(id);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: own ? c.chatReplyQuoteMe : c.chatReplyQuoteThem,
          borderRadius: BorderRadius.circular(cornerExtraSmall),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              k.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            Text(
              k.preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
