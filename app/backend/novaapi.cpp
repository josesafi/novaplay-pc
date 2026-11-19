#include "novaapi.h"

#include <QJSEngine>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSettings>
#include <QUrl>
#include <QEventLoop>
#include <QTimer>
#include <thread>
#include <QClipboard>
#include <QGuiApplication>

#include "qrcodegen/qrcodegen.hpp"

#ifdef Q_OS_WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#endif

// Direccion de la API de Nova Play (la misma del panel). Para pruebas se puede cambiar con la variable NOVAPLAY_API.
static QString apiBase()
{
    QByteArray env = qgetenv("NOVAPLAY_API");
    return env.isEmpty() ? QStringLiteral("https://api.novawebcolombia.com") : QString::fromUtf8(env);
}

static const QByteArray kSessionCookie = QByteArrayLiteral("__Host-novacloud_session");

NovaApi* NovaApi::s_Instance = nullptr;

NovaApi::NovaApi(QObject* parent) : QObject(parent)
{
    s_Instance = this;
    loadSession();
}

void NovaApi::closeGameAsync(std::function<void(int status)> done)
{
    NovaApi* api = s_Instance;
    if (api == nullptr || api->m_Session.isEmpty() || api->m_PlayAccount.isEmpty()) {
        done(0);
        return;
    }
    const QUrl url(apiBase() + "/api/v1/accounts/" + api->m_PlayAccount + "/play/close-game");
    const QByteArray cookie = kSessionCookie + "=" + api->m_Session.toUtf8();
    const QByteArray csrf = api->m_Csrf.toUtf8();
    std::thread([url, cookie, csrf, done]() {
        int status = 0;
        {
            QNetworkAccessManager nam;
            QNetworkRequest req(url);
            req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
            req.setRawHeader("Accept", "application/json");
            req.setRawHeader("User-Agent", "NovaPlay-PC");
            req.setRawHeader("Cookie", cookie);
            if (!csrf.isEmpty()) req.setRawHeader("X-CSRF-Token", csrf);
            QEventLoop loop;
            QNetworkReply* reply = nam.post(req, QByteArray("{}"));
            QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
            QTimer::singleShot(15000, &loop, &QEventLoop::quit);
            loop.exec();
            if (reply->isFinished()) status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            else reply->abort();
            delete reply;
        }
        done(status);
    }).detach();
}

void NovaApi::loadSession()
{
    QSettings s;
    m_Session = s.value("novaplay/session").toString();
    m_Csrf = s.value("novaplay/csrf").toString();
    m_FirstName = s.value("novaplay/firstName").toString();
    m_Email = s.value("novaplay/email").toString();
    m_TwoFactorEnabled = s.value("novaplay/twoFactorEnabled").toBool();
}

void NovaApi::saveSession()
{
    QSettings s;
    s.setValue("novaplay/session", m_Session);
    s.setValue("novaplay/csrf", m_Csrf);
    s.setValue("novaplay/firstName", m_FirstName);
    s.setValue("novaplay/email", m_Email);
    s.setValue("novaplay/twoFactorEnabled", m_TwoFactorEnabled);
    emit sessionChanged();
}

void NovaApi::takeSessionCookie(QNetworkReply* reply)
{
    const QByteArray prefix = kSessionCookie + "=";
    for (const auto& pair : reply->rawHeaderPairs()) {
        if (pair.first.compare("Set-Cookie", Qt::CaseInsensitive) != 0) {
            continue;
        }
        // Qt junta varias cookies de la misma respuesta con saltos de linea
        for (const QByteArray& line : pair.second.split('\n')) {
            int at = line.indexOf(prefix);
            if (at < 0) {
                continue;
            }
            QByteArray value = line.mid(at + prefix.size());
            int end = value.indexOf(';');
            if (end >= 0) {
                value = value.left(end);
            }
            if (!value.isEmpty()) {
                m_Session = QString::fromUtf8(value);
            }
        }
    }
}

QString NovaApi::errorMessage(int status, const QVariant& body)
{
    // la API responde { error: { code, message } } o { message }
    QVariantMap m = body.toMap();
    QString msg = m.value("error").toMap().value("message").toString();
    if (msg.isEmpty()) {
        msg = m.value("message").toString();
    }
    if (!msg.isEmpty()) {
        return msg;
    }
    if (status == 0) {
        return tr("No hay conexión con Nova Play. Revisa tu internet e inténtalo de nuevo.");
    }
    if (status == 401) {
        return tr("Correo o contraseña incorrectos.");
    }
    if (status == 429) {
        return tr("Demasiados intentos. Espera unos minutos e inténtalo de nuevo.");
    }
    return tr("Algo salió mal (código %1). Inténtalo de nuevo.").arg(status);
}

void NovaApi::send(const QByteArray& method, const QString& path, const QVariant& body, bool authed, Done done)
{
    QNetworkRequest req(QUrl(apiBase() + path));
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("User-Agent", "NovaPlay-PC");
    if (authed && !m_Session.isEmpty()) {
        req.setRawHeader("Cookie", kSessionCookie + "=" + m_Session.toUtf8());
        if (!m_Csrf.isEmpty()) {
            req.setRawHeader("X-CSRF-Token", m_Csrf.toUtf8());
        }
    }
    QByteArray payload;
    if (body.isValid() && !body.isNull()) {
        payload = QJsonDocument::fromVariant(body).toJson(QJsonDocument::Compact);
    }
    QNetworkReply* reply = m_Nam.sendCustomRequest(req, method, payload);
    connect(reply, &QNetworkReply::finished, this, [this, reply, authed, done]() {
        reply->deleteLater();
        int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QVariant parsed = QJsonDocument::fromJson(reply->readAll()).toVariant();
        takeSessionCookie(reply);
        if (authed && status == 401 && !m_Session.isEmpty()) {
            // sesion vencida o cerrada desde el panel: se olvida y la app vuelve a la pantalla de inicio de sesion
            m_Session.clear();
            m_Csrf.clear();
            saveSession();
            emit sessionExpired();
        }
        if (done) {
            done(status, parsed);
        }
    });
}

void NovaApi::callJs(QJSValue callback, const QJSValueList& args)
{
    if (callback.isCallable()) {
        callback.call(args);
    }
}

void NovaApi::finishLogin(const QVariant& body, QJSValue callback)
{
    m_Csrf = body.toMap().value("csrfToken").toString();
    // nombre para el saludo
    send("GET", "/api/v1/auth/session", QVariant(), true, [this, callback](int, const QVariant& s) {
        QVariantMap user = s.toMap().value("user").toMap();
        m_FirstName = user.value("firstName").toString();
        m_TwoFactorEnabled = user.value("twoFactorEnabled").toBool();
        if (!user.value("email").toString().isEmpty()) {
            m_Email = user.value("email").toString();
        }
        QString csrf = s.toMap().value("csrfToken").toString();
        if (!csrf.isEmpty()) {
            m_Csrf = csrf;
        }
        saveSession();
        // recordar (o no) el correo y la contrasena de este inicio de sesion
        QSettings st;
        st.setValue("novaplay/savedEmail", rememberEmail() ? m_Email : QString());
        if (rememberPassword() && !m_PendingPassword.isEmpty()) {
            storePassword(m_Email, m_PendingPassword);
        }
        m_PendingPassword.fill(QChar(0));
        m_PendingPassword.clear();
        emit rememberChanged();
        callJs(callback, { QJSValue(true), QJSValue(false), QJSValue(QString()) });
    });
}

void NovaApi::login(QString email, QString password, QJSValue callback)
{
    m_Email = email.trimmed();
    m_Session.clear();
    m_PendingPassword = password;
    QVariantMap body{{"email", m_Email}, {"password", password}};
    send("POST", "/api/v1/auth/login", body, false, [this, callback](int status, const QVariant& r) {
        if (status != 200 && status != 201) {
            m_PendingPassword.clear();
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(errorMessage(status, r)) });
            return;
        }
        QVariantMap m = r.toMap();
        if (m.value("twoFactorRequired").toBool()) {
            m_Challenge = m.value("challengeId").toString();
            callJs(callback, { QJSValue(true), QJSValue(true), QJSValue(QString()) });
            return;
        }
        if (m_Session.isEmpty()) {
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(tr("No se pudo iniciar la sesión. Inténtalo de nuevo.")) });
            return;
        }
        finishLogin(r, callback);
    });
}

void NovaApi::loginTwoFactor(QString code, QJSValue callback)
{
    QString clean = code.trimmed().remove(' ');
    // 6 digitos = codigo de la app autenticadora; otra cosa = codigo de recuperacion
    bool totp = QRegularExpression(QStringLiteral("^[0-9]{6}$")).match(clean).hasMatch();
    QVariantMap body{{"challengeId", m_Challenge}, {totp ? "code" : "recoveryCode", clean}};
    send("POST", "/api/v1/auth/login/2fa", body, false, [this, callback](int status, const QVariant& r) {
        if ((status != 200 && status != 201) || m_Session.isEmpty()) {
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(errorMessage(status, r)) });
            return;
        }
        finishLogin(r, callback);
    });
}

void NovaApi::logout()
{
    if (!m_Session.isEmpty()) {
        send("POST", "/api/v1/auth/logout", QVariantMap(), true, nullptr);
    }
    m_Session.clear();
    m_Csrf.clear();
    m_FirstName.clear();
    m_TwoFactorEnabled = false;
    if (!rememberEmail()) {
        m_Email.clear();
    }
    saveSession();
}

void NovaApi::get(QString path, QJSValue callback)
{
    send("GET", path, QVariant(), true, [this, callback](int status, const QVariant& body) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(body) : QJSValue() });
    });
}

void NovaApi::post(QString path, QVariant body, QJSValue callback)
{
    send("POST", path, body, true, [this, callback](int status, const QVariant& r) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(r) : QJSValue() });
    });
}

// ------------------------------------------------------------------ recordar correo y contrasena

bool NovaApi::rememberEmail() const { return QSettings().value("novaplay/rememberEmail", true).toBool(); }
bool NovaApi::rememberPassword() const { return canRememberPassword() && QSettings().value("novaplay/rememberPassword", false).toBool(); }
QString NovaApi::savedEmail() const { return QSettings().value("novaplay/savedEmail", m_Email).toString(); }

bool NovaApi::canRememberPassword() const
{
#ifdef Q_OS_WIN32
    return true;
#else
    return false;
#endif
}

void NovaApi::setRememberEmail(bool on)
{
    QSettings s;
    s.setValue("novaplay/rememberEmail", on);
    if (!on) {
        // sin recordar el correo tampoco se recuerda la contrasena
        s.remove("novaplay/savedEmail");
        s.setValue("novaplay/rememberPassword", false);
        forgetSavedPassword();
    }
    emit rememberChanged();
}

void NovaApi::setRememberPassword(bool on)
{
    QSettings s;
    s.setValue("novaplay/rememberPassword", on && canRememberPassword());
    if (on) {
        s.setValue("novaplay/rememberEmail", true);
    } else {
        forgetSavedPassword();
    }
    emit rememberChanged();
}

#ifdef Q_OS_WIN32
static std::wstring credTarget(const QString& email)
{
    return (QStringLiteral("NovaPlay:") + email.trimmed().toLower()).toStdWString();
}
#endif

void NovaApi::storePassword(const QString& email, const QString& password)
{
#ifdef Q_OS_WIN32
    if (email.trimmed().isEmpty()) {
        return;
    }
    std::wstring target = credTarget(email);
    std::wstring user = email.trimmed().toStdWString();
    QByteArray blob = password.toUtf8();
    CREDENTIALW c = {};
    c.Type = CRED_TYPE_GENERIC;
    c.TargetName = const_cast<LPWSTR>(target.c_str());
    c.UserName = const_cast<LPWSTR>(user.c_str());
    c.CredentialBlobSize = (DWORD)blob.size();
    c.CredentialBlob = reinterpret_cast<LPBYTE>(blob.data());
    c.Persist = CRED_PERSIST_LOCAL_MACHINE;
    // si antes se guardo la de otro correo, se borra: solo queda la de la ultima cuenta que entro
    QSettings s;
    QString before = s.value("novaplay/passwordFor").toString();
    if (!before.isEmpty() && before != email.trimmed().toLower()) {
        deletePassword(before);
    }
    if (CredWriteW(&c, 0)) {
        s.setValue("novaplay/passwordFor", email.trimmed().toLower());
    }
    blob.fill(0);
#else
    Q_UNUSED(email);
    Q_UNUSED(password);
#endif
}

void NovaApi::deletePassword(const QString& email)
{
#ifdef Q_OS_WIN32
    if (!email.trimmed().isEmpty()) {
        CredDeleteW(credTarget(email).c_str(), CRED_TYPE_GENERIC, 0);
    }
#else
    Q_UNUSED(email);
#endif
}

QString NovaApi::savedPassword(QString email) const
{
#ifdef Q_OS_WIN32
    if (!rememberPassword() || email.trimmed().isEmpty()) {
        return QString();
    }
    PCREDENTIALW c = nullptr;
    if (!CredReadW(credTarget(email).c_str(), CRED_TYPE_GENERIC, 0, &c) || !c) {
        return QString();
    }
    QString pw = QString::fromUtf8(reinterpret_cast<const char*>(c->CredentialBlob), (int)c->CredentialBlobSize);
    CredFree(c);
    return pw;
#else
    Q_UNUSED(email);
    return QString();
#endif
}

void NovaApi::forgetSavedPassword()
{
    QSettings s;
    QString who = s.value("novaplay/passwordFor").toString();
    if (!who.isEmpty()) {
        deletePassword(who);
    }
    s.remove("novaplay/passwordFor");
}

// ------------------------------------------------------------------ llamadas sin sesion, sesion, QR y portapapeles

void NovaApi::publicGet(QString path, QJSValue callback)
{
    send("GET", path, QVariant(), false, [this, callback](int status, const QVariant& body) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(body) : QJSValue() });
    });
}

void NovaApi::publicPost(QString path, QVariant body, QJSValue callback)
{
    send("POST", path, body, false, [this, callback](int status, const QVariant& r) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(r) : QJSValue() });
    });
}

void NovaApi::refreshSession()
{
    if (m_Session.isEmpty()) {
        return;
    }
    send("GET", "/api/v1/auth/session", QVariant(), true, [this](int status, const QVariant& s) {
        if (status != 200) {
            return;
        }
        QVariantMap user = s.toMap().value("user").toMap();
        m_TwoFactorEnabled = user.value("twoFactorEnabled").toBool();
        QString csrf = s.toMap().value("csrfToken").toString();
        if (!csrf.isEmpty()) {
            m_Csrf = csrf;
        }
        saveSession();
    });
}

QVariantMap NovaApi::qrCode(QString text) const
{
    QVariantMap out;
    try {
        qrcodegen::QrCode qr = qrcodegen::QrCode::encodeText(text.toUtf8().constData(), qrcodegen::QrCode::Ecc::MEDIUM);
        int n = qr.getSize();
        QVariantList modules;
        modules.reserve(n * n);
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                modules.append(qr.getModule(x, y));
            }
        }
        out.insert("size", n);
        out.insert("modules", modules);
    } catch (...) {
        out.insert("size", 0);
    }
    return out;
}

void NovaApi::copyText(QString text) const
{
    if (QGuiApplication::clipboard()) {
        QGuiApplication::clipboard()->setText(text);
    }
}
