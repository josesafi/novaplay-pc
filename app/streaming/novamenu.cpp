#include "novamenu.h"
#include "session.h"
#include "input/input.h"
#include "settings/streamingpreferences.h"

#include <QFile>
#include "backend/novaapi.h"
#include <Limelight.h>
#include <QSettings>

using namespace Overlay;

// ---------------------------------------------------------------- colores de la marca (ARGB)
static const SDL_Color C_TEXT = {0xF2, 0xF5, 0xFF, 0xFF};
static const SDL_Color C_MUTED = {0x9C, 0xA9, 0xC9, 0xFF};
static const SDL_Color C_ACCENT = {0x22, 0xD3, 0xEE, 0xFF};
static const SDL_Color C_VIOLET = {0xA7, 0x8B, 0xFA, 0xFF};
static const SDL_Color C_WARN = {0xFA, 0xCC, 0x15, 0xFF};
static const SDL_Color C_DARK = {0x0A, 0x10, 0x30, 0xFF};

static Uint32 argb(SDL_Surface* s, SDL_Color c, Uint8 a)
{
    return SDL_MapRGBA(s->format, c.r, c.g, c.b, a);
}

// rectangulo redondeado con alfa (sin antialias: se ve bien al tamano del menu)
static void fillRounded(SDL_Surface* s, SDL_Rect r, int radius, Uint32 color)
{
    radius = SDL_min(radius, SDL_min(r.w, r.h) / 2);
    for (int y = 0; y < r.h; y++) {
        int inset = 0;
        int dy = y < radius ? radius - y : (y >= r.h - radius ? y - (r.h - radius - 1) : 0);
        if (dy > 0) {
            double dx = radius - SDL_sqrt((double)radius * radius - (double)dy * dy);
            inset = (int)(dx + 0.5);
        }
        SDL_Rect line = {r.x + inset, r.y + y, r.w - 2 * inset, 1};
        if (line.w > 0) {
            SDL_FillRect(s, &line, color);
        }
    }
}

static int text(SDL_Surface* dst, TTF_Font* f, const QString& t, int x, int y, SDL_Color c, int maxW = 0)
{
    if (f == nullptr || t.isEmpty()) {
        return 0;
    }
    QByteArray u = t.toUtf8();
    SDL_Surface* ts = TTF_RenderUTF8_Blended(f, u.constData(), c);
    if (ts == nullptr) {
        return 0;
    }
    SDL_Rect src = {0, 0, maxW > 0 ? SDL_min(ts->w, maxW) : ts->w, ts->h};
    SDL_Rect d = {x, y, src.w, src.h};
    SDL_SetSurfaceBlendMode(ts, SDL_BLENDMODE_BLEND);
    SDL_BlitSurface(ts, &src, dst, &d);
    int w = ts->w;
    SDL_FreeSurface(ts);
    return w;
}

static int textWidth(TTF_Font* f, const QString& t)
{
    int w = 0, h = 0;
    if (f != nullptr) {
        TTF_SizeUTF8(f, t.toUtf8().constData(), &w, &h);
    }
    return w;
}

// ---------------------------------------------------------------- ciclo de vida

NovaMenu::NovaMenu(Session* session)
    : m_Session(session)
{
    QFile f(QString::fromUtf8(":/res/Sora.ttf"));
    if (f.open(QIODevice::ReadOnly)) {
        m_FontData = f.readAll();
    }
    if (m_FontData.isEmpty()) {
        m_FontData = session->getOverlayManager().fontData();
    }
    // el boton «N» se ve los primeros 8 s para que la persona sepa que existe
    m_ButtonVisible = true;
    m_ButtonUntil = SDL_GetTicks() + 8000;
    m_RedrawTicks = 2;
}

NovaMenu::~NovaMenu()
{
    clearOverlay();
    for (auto& cf : m_Fonts) {
        TTF_CloseFont(cf.font);
    }
}

TTF_Font* NovaMenu::font(int px, bool bold)
{
    for (auto& cf : m_Fonts) {
        if (cf.px == px && cf.bold == bold) {
            return cf.font;
        }
    }
    if (m_FontData.isEmpty() || TTF_WasInit() == 0) {
        return nullptr;
    }
    TTF_Font* f = TTF_OpenFontRW(SDL_RWFromConstMem(m_FontData.constData(), m_FontData.size()), 1, px);
    if (f == nullptr) {
        return nullptr;
    }
    if (bold) {
        TTF_SetFontStyle(f, TTF_STYLE_BOLD);
    }
    m_Fonts.append({px, bold, f});
    return f;
}

float NovaMenu::scale() const
{
    int w = 0, h = 0;
#if SDL_VERSION_ATLEAST(2, 26, 0)
    SDL_GetWindowSizeInPixels(m_Session->m_Window, &w, &h);
#else
    SDL_GetWindowSize(m_Session->m_Window, &w, &h);
#endif
    float s = h > 0 ? h / 1080.0f : 1.0f;
    return SDL_clamp(s, 0.7f, 2.0f);
}

void NovaMenu::toSurface(int wx, int wy, int& sx, int& sy) const
{
    // el overlay se dibuja en pixeles reales arriba a la izquierda; los eventos del raton vienen en puntos de la ventana
    int ww = 0, wh = 0, pw = 0, ph = 0;
    SDL_GetWindowSize(m_Session->m_Window, &ww, &wh);
#if SDL_VERSION_ATLEAST(2, 26, 0)
    SDL_GetWindowSizeInPixels(m_Session->m_Window, &pw, &ph);
#else
    pw = ww;
    ph = wh;
#endif
    sx = ww > 0 ? wx * pw / ww : wx;
    sy = wh > 0 ? wy * ph / wh : wy;
}

void NovaMenu::clearOverlay()
{
    m_Session->getOverlayManager().setOverlayCustomSurface(OverlayDebug, nullptr);
}

// ---------------------------------------------------------------- contenido

static QStringList resolutions() { return {"1280×720", "1600×900", "1920×1080", "2560×1440", "3840×2160"}; }
static const int RES_W[] = {1280, 1600, 1920, 2560, 3840};
static const int RES_H[] = {720, 900, 1080, 1440, 2160};
static const int FPS_V[] = {30, 60, 90, 120, 144};

void NovaMenu::build()
{
    StreamingPreferences* p = m_Session->m_Preferences;
    m_Rows.clear();
    auto add = [this](Row r) { m_Rows.append(r); };

    m_StartWidth = p->width;
    m_StartHeight = p->height;
    m_StartFps = p->fps;
    m_StartBitrate = p->bitrateKbps;
    m_StartCodec = p->videoCodecConfig == StreamingPreferences::VCC_FORCE_H264 ? 1 : p->videoCodecConfig == StreamingPreferences::VCC_FORCE_HEVC ? 2 : 0;
    m_StartVsync = p->enableVsync;

    add({Header, IdNone, QString::fromUtf8("JUEGO")});
    Row cg{Action, IdCloseGame, QString::fromUtf8("Cerrar el juego")};
    cg.hint = QString::fromUtf8("Si el juego se congeló: lo cierra sin terminar tu sesión");
    add(cg);
    add({Header, IdNone, QString::fromUtf8("VIDEO")});
    Row res{Choice, IdResolution, QString::fromUtf8("Resolución"), resolutions()};
    res.reconnect = true;
    res.index = 2;
    for (int i = 0; i < 5; i++) if (RES_W[i] == p->width && RES_H[i] == p->height) res.index = i;
    if (!(RES_W[res.index] == p->width && RES_H[res.index] == p->height)) {
        res.options.append(QString("%1×%2").arg(p->width).arg(p->height));
        res.index = res.options.size() - 1;
    }
    add(res);
    Row fps{Choice, IdFps, QString::fromUtf8("Cuadros por segundo"), {"30", "60", "90", "120", "144"}};
    fps.reconnect = true;
    fps.index = 1;
    for (int i = 0; i < 5; i++) if (FPS_V[i] == p->fps) fps.index = i;
    add(fps);
    Row br{Slider, IdBitrate, QString::fromUtf8("Bitrate")};
    br.reconnect = true;
    br.min = 5; br.max = 150; br.step = 5;
    br.value = SDL_clamp((p->bitrateKbps + 500) / 1000, 5, 150);
    add(br);
    Row codec{Choice, IdCodec, QString::fromUtf8("Códec"), {"Automático", "H.264", "H.265"}};
    codec.reconnect = true;
    codec.index = m_StartCodec;
    codec.hint = QString::fromUtf8("AV1 no: la tarjeta de la consola no lo codifica");
    add(codec);
    Row vs{Toggle, IdVsync, QString::fromUtf8("V-Sync (sin cortes en la imagen)")};
    vs.reconnect = true;
    vs.index = p->enableVsync ? 1 : 0;
    add(vs);
    Row win{Choice, IdWindow, QString::fromUtf8("Pantalla"), {"Ventana", "Pantalla completa"}};
    win.index = (SDL_GetWindowFlags(m_Session->m_Window) & m_Session->m_FullScreenFlag) ? 1 : 0;
    add(win);
    QSettings st;
    if (st.contains("novaplay/red/kbps")) {
        Row net{Action, IdNetwork, QString("Usar lo recomendado por mi red · %1p %2 FPS · %3 Mbps")
                .arg(st.value("novaplay/red/height").toInt()).arg(st.value("novaplay/red/fps").toInt()).arg(st.value("novaplay/red/kbps").toInt() / 1000)};
        net.hint = QString::fromUtf8("Según tu última Prueba de red");
        add(net);
    }

    add({Header, IdNone, QString::fromUtf8("SONIDO")});
    Row dev{Choice, IdAudioDevice, QString::fromUtf8("Salida"), {"Predeterminado de Windows"}};
    QString cur = st.value("novaplay/audioDevice").toString();
    if (SDL_WasInit(SDL_INIT_AUDIO)) {
        int n = SDL_GetNumAudioDevices(0);
        for (int i = 0; i < n; i++) {
            const char* name = SDL_GetAudioDeviceName(i, 0);
            if (name != nullptr) {
                dev.options.append(QString::fromUtf8(name));
                if (cur == QString::fromUtf8(name)) dev.index = dev.options.size() - 1;
            }
        }
    }
    add(dev);
    Row vol{Slider, IdVolume, QString::fromUtf8("Volumen")};
    vol.min = 0; vol.max = 100; vol.step = 5;
    vol.value = (int)(m_Session->m_NovaVolume * 100 + 0.5f);
    add(vol);
    Row mute{Toggle, IdMute, QString::fromUtf8("Silenciar")};
    mute.index = m_Session->m_NovaMute ? 1 : 0;
    add(mute);

    add({Header, IdNone, QString::fromUtf8("ENTRADA")});
    QStringList pads = m_Session->m_InputHandler != nullptr ? m_Session->m_InputHandler->connectedGamepadNames() : QStringList();
    Row gp{Info, IdGamepads, QString::fromUtf8("Mandos"), {pads.isEmpty() ? QString::fromUtf8("Ninguno conectado") : pads.join("  ·  ")}};
    add(gp);
    Row mm{Choice, IdMouseMode, QString::fromUtf8("Ratón"), {"Para juegos (relativo)", "Para escritorio (absoluto)"}};
    mm.index = (m_Session->m_InputHandler != nullptr && m_Session->m_InputHandler->isAbsoluteMouseMode()) ? 1 : 0;
    add(mm);
    Row cap{Toggle, IdCapture, QString::fromUtf8("Capturar el ratón al cerrar este menú")};
    cap.index = m_CaptureOnClose ? 1 : 0;
    add(cap);

    add({Header, IdNone, QString::fromUtf8("PANTALLA")});
    Row stats{Toggle, IdStats, QString::fromUtf8("Estadísticas en pantalla")};
    stats.index = m_Session->getOverlayManager().overlayEnabledAfterCustom(OverlayDebug) ? 1 : 0;
    add(stats);
    add({Info, IdKeys, QString::fromUtf8("Atajos"),
         {QString::fromUtf8("Ctrl+Alt+Shift+N este menú · Q desconectar · X pantalla completa · Z liberar ratón · S estadísticas"),
          QString::fromUtf8("Mando: Select+Start 1 s este menú · Start+Select+L1+R1 desconectar")}});

    add({Action, IdApply, QString::fromUtf8("Aplicar y reconectar")});
    add({Action, IdClose, QString::fromUtf8("Cerrar")});

    m_Selected = 1;
}

NovaMenu::Row* NovaMenu::rowById(Id id)
{
    for (auto& r : m_Rows) if (r.id == id) return &r;
    return nullptr;
}

bool NovaMenu::pendingReconnect() const
{
    for (const auto& r : m_Rows) {
        if (!r.reconnect) continue;
        switch (r.id) {
        case IdResolution: {
            int w = r.index < 5 ? RES_W[r.index] : m_StartWidth, h = r.index < 5 ? RES_H[r.index] : m_StartHeight;
            if (w != m_StartWidth || h != m_StartHeight) return true;
            break;
        }
        case IdFps: if (FPS_V[r.index] != m_StartFps) return true; break;
        case IdBitrate: if (r.value * 1000 != m_StartBitrate && SDL_abs(r.value * 1000 - m_StartBitrate) >= 500) return true; break;
        case IdCodec: if (r.index != m_StartCodec) return true; break;
        case IdVsync: if ((r.index == 1) != m_StartVsync) return true; break;
        default: break;
        }
    }
    return false;
}

// ---------------------------------------------------------------- dibujo

void NovaMenu::render()
{
    const float s = scale();
    const int W = (int)(620 * s), pad = (int)(22 * s), rowH = (int)(38 * s), headH = (int)(30 * s);
    TTF_Font* fTitle = font((int)(22 * s), true);
    TTF_Font* fRow = font((int)(15 * s), false);
    TTF_Font* fBold = font((int)(15 * s), true);
    TTF_Font* fSmall = font((int)(12 * s), false);
    TTF_Font* fHead = font((int)(11.5f * s), true);

    // alto total
    int H = pad + (int)(56 * s);
    for (const auto& r : m_Rows) {
        if (r.kind == Header) H += headH;
        else if (r.kind == Info) H += (int)(r.options.size() > 1 ? 50 * s : 34 * s);
        else if (r.kind == Action && (r.id == IdApply || r.id == IdClose)) continue;
        else H += rowH + (r.hint.isEmpty() ? 0 : (int)(14 * s));
    }
    H += (int)(70 * s) + (m_Status.isEmpty() ? 0 : (int)(24 * s)) + pad;

    SDL_Surface* sf = SDL_CreateRGBSurfaceWithFormat(0, W + (int)(16 * s), H + (int)(16 * s), 32, SDL_PIXELFORMAT_ARGB8888);
    if (sf == nullptr) return;
    SDL_FillRect(sf, nullptr, SDL_MapRGBA(sf->format, 0, 0, 0, 0));
    const int ox = (int)(12 * s), oy = (int)(12 * s);
    // borde de la marca y fondo
    fillRounded(sf, {ox - 2, oy - 2, W + 4, H + 4}, (int)(20 * s), argb(sf, C_VIOLET, 0xB0));
    fillRounded(sf, {ox, oy, W, H}, (int)(18 * s), argb(sf, C_DARK, 0xF2));

    int y = oy + pad;
    int x = ox + pad;
    text(sf, fTitle, QString::fromUtf8("Ajustes de la transmisión"), x, y, C_TEXT);
    text(sf, fSmall, m_Reconnecting ? QString::fromUtf8("Reconectando… tu juego sigue abierto") : QString::fromUtf8("Esc o B para cerrar · ↑↓ elegir · ←→ cambiar"),
         x, y + (int)(30 * s), m_Reconnecting ? C_WARN : C_MUTED);
    y += (int)(56 * s);

    const int labelW = (int)(250 * s);
    for (int i = 0; i < m_Rows.size(); i++) {
        Row& r = m_Rows[i];
        if (r.kind == Action && (r.id == IdApply || r.id == IdClose)) continue;
        if (r.kind == Header) {
            text(sf, fHead, r.label, x, y + (int)(10 * s), C_ACCENT);
            r.rect = {0, 0, 0, 0};
            y += headH;
            continue;
        }
        int h = r.kind == Info ? (int)(r.options.size() > 1 ? 50 * s : 34 * s) : rowH + (r.hint.isEmpty() ? 0 : (int)(14 * s));
        r.rect = {ox + (int)(8 * s), y, W - (int)(16 * s), h};
        bool sel = i == m_Selected && r.kind != Info;
        if (sel) {
            fillRounded(sf, r.rect, (int)(10 * s), argb(sf, C_ACCENT, 0x26));
        }
        int ty = y + (rowH - TTF_FontHeight(fRow)) / 2;
        if (r.kind == Info) {
            text(sf, fRow, r.label, x, y + (int)(6 * s), C_MUTED);
            for (int k = 0; k < r.options.size(); k++) {
                text(sf, fSmall, r.options[k], x + (k == 0 && r.id == IdGamepads ? labelW : 0), y + (int)((k == 0 && r.id == IdGamepads ? 8 : 24 + 16 * (k - 1)) * s) + (r.id == IdKeys && k == 0 ? (int)(-2 * s) : 0),
                     C_TEXT, W - pad * 2 - (k == 0 && r.id == IdGamepads ? labelW : 0));
            }
            y += h;
            continue;
        }
        QString label = r.label + (r.reconnect ? QString::fromUtf8("  ↻") : QString());
        text(sf, sel ? fBold : fRow, label, x, ty, C_TEXT, labelW - (int)(8 * s));
        int vx = ox + labelW + pad, vw = W - labelW - pad * 2;
        if (r.kind == Choice) {
            QString v = r.options.value(r.index);
            text(sf, fBold, QString::fromUtf8("‹"), vx, ty, sel ? C_ACCENT : C_MUTED);
            int tw = textWidth(fBold, v);
            int maxTw = vw - (int)(40 * s);
            text(sf, fBold, v, vx + (vw - SDL_min(tw, maxTw)) / 2, ty, C_TEXT, maxTw);
            text(sf, fBold, QString::fromUtf8("›"), vx + vw - (int)(10 * s), ty, sel ? C_ACCENT : C_MUTED);
        }
        else if (r.kind == Toggle) {
            SDL_Rect track = {vx + vw - (int)(52 * s), y + (rowH - (int)(24 * s)) / 2, (int)(48 * s), (int)(24 * s)};
            fillRounded(sf, track, track.h / 2, r.index ? argb(sf, C_ACCENT, 0xFF) : argb(sf, C_MUTED, 0x60));
            SDL_Rect knob = {r.index ? track.x + track.w - track.h + (int)(3 * s) : track.x + (int)(3 * s), track.y + (int)(3 * s), track.h - (int)(6 * s), track.h - (int)(6 * s)};
            fillRounded(sf, knob, knob.h / 2, argb(sf, C_TEXT, 0xFF));
            text(sf, fSmall, r.index ? QString::fromUtf8("Sí") : QString::fromUtf8("No"), track.x - (int)(34 * s), ty + (int)(2 * s), C_MUTED);
        }
        else if (r.kind == Slider) {
            QString v = r.id == IdBitrate ? QString("%1 Mbps").arg(r.value) : QString("%1 %").arg(r.value);
            int valW = (int)(86 * s);
            SDL_Rect track = {vx, y + rowH / 2 - (int)(3 * s), vw - valW, (int)(6 * s)};
            fillRounded(sf, track, track.h / 2, argb(sf, C_MUTED, 0x50));
            int fillW = (int)((double)(r.value - r.min) / (r.max - r.min) * track.w);
            fillRounded(sf, {track.x, track.y, SDL_max(fillW, track.h), track.h}, track.h / 2, argb(sf, C_ACCENT, 0xFF));
            fillRounded(sf, {track.x + fillW - (int)(8 * s), track.y - (int)(5 * s), (int)(16 * s), (int)(16 * s)}, (int)(8 * s), argb(sf, C_TEXT, 0xFF));
            text(sf, fBold, v, track.x + track.w + (int)(14 * s), ty, C_TEXT);
            if (r.id == IdBitrate) {
                // marcas: Ahorro 10 · Recomendado (segun resolucion y FPS) · Maxima 150
                Row* res = rowById(IdResolution);
                Row* fr = rowById(IdFps);
                int rw = res && res->index < 5 ? RES_W[res->index] : m_StartWidth, rh = res && res->index < 5 ? RES_H[res->index] : m_StartHeight;
                int rec = SDL_clamp(StreamingPreferences::getDefaultBitrate(rw, rh, fr ? FPS_V[fr->index] : 60, false) / 1000, 5, 150);
                struct { int v; const char* t; } marks[] = {{10, "Ahorro"}, {rec, "Recomendado"}, {150, "Máxima"}};
                for (auto& m : marks) {
                    int mx = track.x + (int)((double)(m.v - r.min) / (r.max - r.min) * track.w);
                    QString t = QString::fromUtf8(m.t);
                    int tw = textWidth(fSmall, t);
                    text(sf, fSmall, t, SDL_clamp(mx - tw / 2, track.x, track.x + track.w - tw), y + rowH - (int)(4 * s), C_MUTED);
                }
            }
        }
        else if (r.kind == Action && r.id == IdCloseGame) {
            QString t = m_CloseState == 2 ? QString::fromUtf8("Cerrando…") : m_CloseState == 1 ? QString::fromUtf8("Sí, cerrar ›") : QString::fromUtf8("Cerrar ›");
            text(sf, fBold, t, vx + vw - textWidth(fBold, t), ty, m_CloseState ? C_WARN : sel ? C_ACCENT : C_MUTED);
        }
        else if (r.kind == Action) {
            text(sf, fBold, QString::fromUtf8("Aplicar ›"), vx + vw - textWidth(fBold, QString::fromUtf8("Aplicar ›")), ty, sel ? C_ACCENT : C_MUTED);
        }
        if (!r.hint.isEmpty()) {
            text(sf, fSmall, r.hint, x, y + rowH - (int)(6 * s), C_MUTED, W - pad * 2);
        }
        y += h;
    }

    // botones de abajo
    y += (int)(12 * s);
    bool pending = pendingReconnect();
    Row* ap = rowById(IdApply);
    Row* cl = rowById(IdClose);
    int bw = (int)(250 * s), bh = (int)(44 * s);
    if (ap != nullptr) {
        ap->rect = {ox + W - pad - bw * 2 - (int)(12 * s), y, bw, bh};
        bool sel = m_Rows.value(m_Selected).id == IdApply;
        fillRounded(sf, ap->rect, bh / 2, pending ? argb(sf, sel ? C_ACCENT : C_VIOLET, 0xFF) : argb(sf, C_MUTED, 0x40));
        QString t = m_Reconnecting ? QString::fromUtf8("Reconectando…") : QString::fromUtf8("Aplicar y reconectar");
        text(sf, fBold, t, ap->rect.x + (bw - textWidth(fBold, t)) / 2, y + (bh - TTF_FontHeight(fBold)) / 2, pending ? C_DARK : C_MUTED);
    }
    if (cl != nullptr) {
        cl->rect = {ox + W - pad - bw, y, bw, bh};
        bool sel = m_Rows.value(m_Selected).id == IdClose;
        fillRounded(sf, cl->rect, bh / 2, argb(sf, sel ? C_ACCENT : C_TEXT, sel ? 0x40 : 0x1A));
        QString t = QString::fromUtf8("Cerrar");
        text(sf, fBold, t, cl->rect.x + (bw - textWidth(fBold, t)) / 2, y + (bh - TTF_FontHeight(fBold)) / 2, C_TEXT);
    }
    y += bh + (int)(10 * s);
    QString foot = pending ? QString::fromUtf8("↻ Se aplica al reconectar: unos segundos, tu juego sigue abierto.")
                           : QString::fromUtf8("Lo demás cambia al instante.");
    text(sf, fSmall, foot, x, y, pending ? C_WARN : C_MUTED, W - pad * 2);
    if (!m_Status.isEmpty()) {
        text(sf, fSmall, m_Status, x, y + (int)(20 * s), C_ACCENT, W - pad * 2);
    }

    m_Session->getOverlayManager().setOverlayCustomSurface(OverlayDebug, sf);
}

void NovaMenu::renderButton()
{
    const float s = scale();
    TTF_Font* fN = font((int)(22 * s), true);
    TTF_Font* fSmall = font((int)(12.5f * s), false);
    QString hint = QString::fromUtf8("Ajustes · Ctrl+Alt+Shift+N");
    int hintW = textWidth(fSmall, hint);
    int size = (int)(44 * s), m = (int)(14 * s);
    SDL_Surface* sf = SDL_CreateRGBSurfaceWithFormat(0, m + size + (int)(10 * s) + hintW + (int)(24 * s), m + size + (int)(4 * s), 32, SDL_PIXELFORMAT_ARGB8888);
    if (sf == nullptr) return;
    SDL_FillRect(sf, nullptr, SDL_MapRGBA(sf->format, 0, 0, 0, 0));
    m_ButtonRect = {m, m, size, size};
    fillRounded(sf, {m - 2, m - 2, size + 4, size + 4}, (int)(14 * s), argb(sf, C_VIOLET, 0xC0));
    fillRounded(sf, m_ButtonRect, (int)(12 * s), argb(sf, C_DARK, 0xD8));
    int tw = textWidth(fN, QString::fromUtf8("N"));
    text(sf, fN, QString::fromUtf8("N"), m + (size - tw) / 2, m + (size - TTF_FontHeight(fN)) / 2, C_ACCENT);
    SDL_Rect pill = {m + size + (int)(8 * s), m + (size - (int)(26 * s)) / 2, hintW + (int)(18 * s), (int)(26 * s)};
    fillRounded(sf, pill, pill.h / 2, argb(sf, C_DARK, 0xC0));
    text(sf, fSmall, hint, pill.x + (int)(9 * s), pill.y + (pill.h - TTF_FontHeight(fSmall)) / 2, C_TEXT);
    m_Session->getOverlayManager().setOverlayCustomSurface(OverlayDebug, sf);
}

// ---------------------------------------------------------------- acciones

void NovaMenu::toggle()
{
    if (m_Open) close();
    else open();
}

void NovaMenu::open()
{
    if (m_Open || m_Session->m_Window == nullptr) return;
    m_Open = true;
    m_ButtonVisible = false;
    m_Status.clear();
    if (m_CloseState == 1) {   // cambiar de opcion o reabrir el panel cancela «¿Cerrar el juego?»
        m_CloseState = 0;
        if (Row* r = rowById(IdCloseGame)) {
            r->label = QString::fromUtf8("Cerrar el juego");
            r->hint = QString::fromUtf8("Si el juego se congeló: lo cierra sin terminar tu sesión");
        }
    }

    if (m_Session->m_InputHandler != nullptr) {
        m_CaptureOnClose = m_Session->m_InputHandler->isCaptureActive() || m_CaptureOnClose;
        m_Session->m_InputHandler->raiseAllKeys();
        // el raton queda libre para tocar el menu
        m_Session->m_InputHandler->setCaptureActive(false);
    }
    build();
    render();
}

void NovaMenu::close()
{
    if (!m_Open) return;
    m_Open = false;
    clearOverlay();
    if (m_Session->m_InputHandler != nullptr && m_CaptureOnClose && !m_Reconnecting) {
        m_Session->m_InputHandler->setCaptureActive(true);
    }
}

void NovaMenu::moveSelection(int delta)
{
    if (m_CloseState == 1) {   // cambiar de opcion o reabrir el panel cancela «¿Cerrar el juego?»
        m_CloseState = 0;
        if (Row* r = rowById(IdCloseGame)) {
            r->label = QString::fromUtf8("Cerrar el juego");
            r->hint = QString::fromUtf8("Si el juego se congeló: lo cierra sin terminar tu sesión");
        }
    }
    int n = m_Rows.size();
    for (int k = 0; k < n; k++) {
        m_Selected = (m_Selected + delta + n) % n;
        Kind kd = m_Rows[m_Selected].kind;
        if (kd != Header && kd != Info) break;
    }
}

void NovaMenu::change(Row& r, int delta)
{
    StreamingPreferences* p = m_Session->m_Preferences;
    if (r.kind == Choice) {
        int n = r.options.size();
        if (n == 0) return;
        r.index = SDL_clamp(r.index + delta, 0, n - 1);
    }
    else if (r.kind == Slider) {
        r.value = SDL_clamp(r.value + delta * r.step, r.min, r.max);
    }
    else if (r.kind == Toggle) {
        r.index = delta > 0 ? 1 : delta < 0 ? 0 : !r.index;
    }
    else {
        return;
    }
    // lo que cambia al instante
    switch (r.id) {
    case IdWindow: {
        bool full = (SDL_GetWindowFlags(m_Session->m_Window) & m_Session->m_FullScreenFlag) != 0;
        if ((r.index == 1) != full) {
            m_Session->toggleFullscreen();
            p->windowMode = r.index == 1 ? p->recommendedFullScreenMode : StreamingPreferences::WM_WINDOWED;
            p->save();
            m_RedrawTicks = 3;   // la pantalla se rehace: el menu se vuelve a dibujar
        }
        break;
    }
    case IdAudioDevice: {
        QSettings st;
        if (r.index == 0) st.remove("novaplay/audioDevice");
        else st.setValue("novaplay/audioDevice", r.options.value(r.index));
        SDL_AtomicSet(&m_Session->m_NovaAudioReset, 1);
        m_Status = QString::fromUtf8("Cambiando la salida de sonido…");
        break;
    }
    case IdVolume:
        m_Session->m_NovaVolume = r.value / 100.0f;
        QSettings().setValue("novaplay/volume", r.value);
        break;
    case IdMute:
        m_Session->m_NovaMute = r.index == 1;
        break;
    case IdMouseMode:
        if (m_Session->m_InputHandler != nullptr) {
            m_Session->m_InputHandler->setAbsoluteMouseMode(r.index == 1);
            // el menu sigue abierto: el raton queda libre hasta cerrarlo
            m_Session->m_InputHandler->setCaptureActive(false);
        }
        break;
    case IdCapture:
        m_CaptureOnClose = r.index == 1;
        break;
    case IdStats:
        m_Session->getOverlayManager().setOverlayEnabledAfterCustom(OverlayDebug, r.index == 1);
        break;
    default:
        break;
    }
}

void NovaMenu::activate(Row& r)
{
    if (r.kind == Toggle) {
        change(r, 0);
    }
    else if (r.kind == Choice || r.kind == Slider) {
        change(r, 1);
    }
    else if (r.id == IdClose) {
        close();
        return;
    }
    else if (r.id == IdCloseGame) {
        if (m_CloseState == 0) {
            m_CloseState = 1;
            r.label = QString::fromUtf8("¿Cerrar el juego?");
            r.hint = QString::fromUtf8("Lo que no hayas guardado se pierde · otra opción o Esc para cancelar");
            m_Status.clear();
        }
        else if (m_CloseState == 1) {
            closeGame();
        }
        render();
        return;
    }
    else if (r.id == IdApply) {
        if (pendingReconnect()) applyAndReconnect();
        return;
    }
    else if (r.id == IdNetwork) {
        QSettings st;
        int h = st.value("novaplay/red/height").toInt(), fps = st.value("novaplay/red/fps").toInt(), kbps = st.value("novaplay/red/kbps").toInt();
        if (Row* res = rowById(IdResolution)) for (int i = 0; i < 5; i++) if (RES_H[i] == h) res->index = i;
        if (Row* fr = rowById(IdFps)) for (int i = 0; i < 5; i++) if (FPS_V[i] == fps) fr->index = i;
        if (Row* br = rowById(IdBitrate)) br->value = SDL_clamp((kbps + 500) / 1000, br->min, br->max);
        m_Status = QString::fromUtf8("Listo: pulsa «Aplicar y reconectar».");
    }
}

void NovaMenu::closeGame()
{
    m_CloseState = 2;
    if (Row* r = rowById(IdCloseGame)) {
        r->label = QString::fromUtf8("Cerrando el juego…");
        r->hint = QString::fromUtf8("En unos segundos vuelves a la pantalla de Nova Play");
    }
    m_Status = QString::fromUtf8("Cerrando el juego… tu sesión sigue abierta.");
    // respaldo sin red: Ctrl+Alt+Fin a la consola (allí también cierra el juego)
    const char mods = MODIFIER_CTRL | MODIFIER_ALT;
    LiSendKeyboardEvent(0x11, KEY_ACTION_DOWN, MODIFIER_CTRL);
    LiSendKeyboardEvent(0x12, KEY_ACTION_DOWN, mods);
    LiSendKeyboardEvent(0x23, KEY_ACTION_DOWN, mods);
    LiSendKeyboardEvent(0x23, KEY_ACTION_UP, mods);
    LiSendKeyboardEvent(0x12, KEY_ACTION_UP, MODIFIER_CTRL);
    LiSendKeyboardEvent(0x11, KEY_ACTION_UP, 0);
    SDL_AtomicSet(&m_CloseResult, -2);
    SDL_atomic_t* out = &m_CloseResult;
    NovaApi::closeGameAsync([out](int status) { SDL_AtomicSet(out, status); });
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Nova Play: cerrar el juego pedido");
}

void NovaMenu::applyAndReconnect()
{
    StreamingPreferences* p = m_Session->m_Preferences;
    Row* res = rowById(IdResolution);
    if (res && res->index < 5) { p->width = RES_W[res->index]; p->height = RES_H[res->index]; }
    if (Row* fr = rowById(IdFps)) p->fps = FPS_V[fr->index];
    if (Row* br = rowById(IdBitrate)) { p->bitrateKbps = br->value * 1000; p->autoAdjustBitrate = false; }
    if (Row* c = rowById(IdCodec)) p->videoCodecConfig = c->index == 1 ? StreamingPreferences::VCC_FORCE_H264 : c->index == 2 ? StreamingPreferences::VCC_FORCE_HEVC : StreamingPreferences::VCC_AUTO;
    if (Row* v = rowById(IdVsync)) p->enableVsync = v->index == 1;
    p->save();
    m_Reconnecting = true;
    render();
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Nova Play: ajustes aplicados, reconectando (%dx%d %d FPS %d kbps)", p->width, p->height, p->fps, p->bitrateKbps);
    m_Session->novaRequestReconnect();
}

// ---------------------------------------------------------------- eventos

int NovaMenu::hitRow(int x, int y) const
{
    for (int i = 0; i < m_Rows.size(); i++) {
        const SDL_Rect& r = m_Rows[i].rect;
        if (r.w > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return i;
    }
    return -1;
}

bool NovaMenu::handleEvent(const SDL_Event& e)
{
    if (e.type == SDL_WINDOWEVENT) {
        // cambio de tamano o de pantalla: el menu (o el boton) se vuelve a dibujar a la nueva escala
        if (m_Open || m_ButtonVisible) m_RedrawTicks = 2;
        return false;
    }
    if (!m_Open) {
        // con el boton a la vista (o el raton libre cerca de la esquina) un clic en la «N» abre el menu
        if (e.type == SDL_MOUSEMOTION && !SDL_GetRelativeMouseMode()) {
            int sx, sy;
            toSurface(e.motion.x, e.motion.y, sx, sy);
            float s = scale();
            if (sx < (int)(90 * s) && sy < (int)(90 * s)) {
                if (!m_ButtonVisible) { m_ButtonVisible = true; renderButton(); }
                m_ButtonUntil = SDL_GetTicks() + 3000;
            }
        }
        if (e.type == SDL_MOUSEBUTTONDOWN && m_ButtonVisible && !SDL_GetRelativeMouseMode()) {
            int sx, sy;
            toSurface(e.button.x, e.button.y, sx, sy);
            const SDL_Rect& b = m_ButtonRect;
            if (sx >= b.x && sx < b.x + b.w && sy >= b.y && sy < b.y + b.h) {
                open();
                return true;
            }
        }
        return false;
    }
    if (m_Reconnecting) {
        // mientras se reconecta solo se ignora la entrada
        return e.type == SDL_KEYDOWN || e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEMOTION || e.type == SDL_CONTROLLERBUTTONDOWN;
    }
    switch (e.type) {
    case SDL_KEYDOWN: {
        SDL_Keycode k = e.key.keysym.sym;
        bool combo = (e.key.keysym.mod & KMOD_CTRL) && (e.key.keysym.mod & KMOD_ALT) && (e.key.keysym.mod & KMOD_SHIFT);
        if (k == SDLK_ESCAPE || (combo && k == SDLK_n)) { close(); return true; }
        if (k == SDLK_UP) moveSelection(-1);
        else if (k == SDLK_DOWN || k == SDLK_TAB) moveSelection(1);
        else if (k == SDLK_LEFT) change(m_Rows[m_Selected], -1);
        else if (k == SDLK_RIGHT) change(m_Rows[m_Selected], 1);
        else if (k == SDLK_RETURN || k == SDLK_KP_ENTER || k == SDLK_SPACE) activate(m_Rows[m_Selected]);
        if (m_Open) render();
        return true;
    }
    case SDL_KEYUP:
        // las teclas que se soltaron mientras el menu esta abierto se dejan pasar (ya se soltaron en la consola al abrirlo)
        return false;
    case SDL_TEXTINPUT:
    case SDL_TEXTEDITING:
        return true;
    case SDL_MOUSEMOTION: {
        int sx, sy;
        toSurface(e.motion.x, e.motion.y, sx, sy);
        int i = hitRow(sx, sy);
        if (i >= 0 && i != m_Selected && m_Rows[i].kind != Info && m_Rows[i].kind != Header) { m_Selected = i; render(); }
        return true;
    }
    case SDL_MOUSEBUTTONDOWN: {
        int sx, sy;
        toSurface(e.button.x, e.button.y, sx, sy);
        int i = hitRow(sx, sy);
        if (i < 0) {
            // clic fuera del menu: se cierra (el clic no llega al juego)
            close();
            return true;
        }
        Row& r = m_Rows[i];
        m_Selected = i;
        const float s = scale();
        int labelW = (int)(250 * s), pad = (int)(22 * s), ox = (int)(12 * s);
        int vx = ox + labelW + pad, vw = r.rect.w + (int)(16 * s) - labelW - pad * 2;
        if (r.kind == Choice) change(r, sx < vx + vw / 2 ? -1 : 1);
        else if (r.kind == Slider) {
            int valW = (int)(86 * s), tw = vw - valW;
            if (sx >= vx && sx <= vx + tw) {
                int v = r.min + (int)((double)(sx - vx) / tw * (r.max - r.min) + 0.5);
                v = (v / r.step) * r.step;
                r.value = SDL_clamp(v, r.min, r.max);
                if (r.id == IdVolume) { m_Session->m_NovaVolume = r.value / 100.0f; QSettings().setValue("novaplay/volume", r.value); }
            }
            else change(r, sx > vx + tw ? 1 : -1);
        }
        else activate(r);
        if (m_Open) render();
        return true;
    }
    case SDL_MOUSEBUTTONUP:
    case SDL_MOUSEWHEEL:
        return true;
    case SDL_CONTROLLERBUTTONDOWN:
        switch (e.cbutton.button) {
        case SDL_CONTROLLER_BUTTON_DPAD_UP: moveSelection(-1); break;
        case SDL_CONTROLLER_BUTTON_DPAD_DOWN: moveSelection(1); break;
        case SDL_CONTROLLER_BUTTON_DPAD_LEFT: change(m_Rows[m_Selected], -1); break;
        case SDL_CONTROLLER_BUTTON_DPAD_RIGHT: change(m_Rows[m_Selected], 1); break;
        case SDL_CONTROLLER_BUTTON_A: activate(m_Rows[m_Selected]); break;
        case SDL_CONTROLLER_BUTTON_B: case SDL_CONTROLLER_BUTTON_BACK: close(); return true;
        default: break;
        }
        if (m_Open) render();
        return true;
    case SDL_CONTROLLERAXISMOTION: {
        // stick izquierdo como cruceta (con zona muerta); los demas ejes pasan a la consola centrados
        static Uint32 last = 0;
        int v = e.caxis.value;
        if (SDL_abs(v) < 16000) return false;
        if (SDL_GetTicks() - last < 220) return true;
        last = SDL_GetTicks();
        if (e.caxis.axis == SDL_CONTROLLER_AXIS_LEFTY) moveSelection(v > 0 ? 1 : -1);
        else if (e.caxis.axis == SDL_CONTROLLER_AXIS_LEFTX) change(m_Rows[m_Selected], v > 0 ? 1 : -1);
        else return true;
        render();
        return true;
    }
    default:
        return false;
    }
}

void NovaMenu::tick()
{
    if (!m_Open && m_Session->m_InputHandler != nullptr && m_Session->m_InputHandler->takeNovaMenuCombo()) {
        open();
        return;
    }
    if (m_RedrawTicks > 0 && --m_RedrawTicks == 0) {
        if (m_Open) render();
        else if (m_ButtonVisible) renderButton();
    }
    if (!m_Open && m_ButtonVisible && SDL_TICKS_PASSED(SDL_GetTicks(), m_ButtonUntil)) {
        m_ButtonVisible = false;
        clearOverlay();
    }
    if (m_CloseState == 2) {
        int st = SDL_AtomicGet(&m_CloseResult);
        if (st != -2) {
            SDL_AtomicSet(&m_CloseResult, -1);
            m_CloseState = 0;
            if (Row* r = rowById(IdCloseGame)) {
                r->label = QString::fromUtf8("Cerrar el juego");
                r->hint = QString::fromUtf8("Si el juego se congeló: lo cierra sin terminar tu sesión");
            }
            if (st == 200) {
                SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Nova Play: la consola esta cerrando el juego");
                if (m_Open) close();
                return;
            }
            // sin respuesta de la API igual se mando Ctrl+Alt+Fin: se avisa sin alarmar
            m_Status = st == 409 ? QString::fromUtf8("La consola no tiene una sesión abierta a tu nombre.")
                     : st == 0 ? QString::fromUtf8("Sin conexión con tu cuenta: se mandó Ctrl+Alt+Fin a la consola; si el juego sigue, inténtalo de nuevo.")
                               : QString::fromUtf8("No se pudo pedir que se cierre el juego (error %1). Inténtalo de nuevo.").arg(st);
            if (m_Open) render();
        }
    }
    if (m_Open && !m_Status.isEmpty() && m_Status.startsWith(QString::fromUtf8("Cambiando la salida")) && SDL_AtomicGet(&m_Session->m_NovaAudioReset) == 0) {
        m_Status = QString::fromUtf8("Salida de sonido cambiada.");
        render();
    }
}
