import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat/api.dart';
import 'chat/chat_state.dart';
import 'chat/home.dart';
import 'chat/theme.dart';
import 'chat/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? setupError;
  try {
    await Firebase.initializeApp();
  } catch (_) {
    setupError =
        'Configure Firebase for Android and iOS using the steps in Standalone/README.md, then rebuild the app.';
  }
  runApp(ChatApp(setupError: setupError));
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key, this.setupError});
  final String? setupError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TMS Connect',
    debugShowCheckedModeBanner: false,
    theme: chatTheme(),
    home: setupError != null
        ? Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(setupError!),
              ),
            ),
          )
        : const AuthGate(),
  );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return snapshot.data == null
          ? const SignIn()
          : AccountLoader(key: ValueKey(snapshot.data!.uid));
    },
  );
}

class SignIn extends StatefulWidget {
  const SignIn({super.key});
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final email = TextEditingController(), password = TextEditingController();
  bool register = false, busy = false, showPassword = false;
  final form = GlobalKey<FormState>();
  String? notice;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      if (register) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email.text.trim(),
          password: password.text,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email.text.trim(),
          password: password.text,
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resetPassword() async {
    if (busy) return;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.text.trim())) {
      setState(() {
        error = 'Enter your email address to reset your password.';
        notice = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: email.text.trim(),
      );
      if (mounted) {
        setState(
          () => notice =
              'If this account exists, a reset email will arrive shortly.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AccountSurface(
    title: register ? 'Create your account' : 'Welcome back',
    subtitle: register
        ? 'Your team is one conversation away.'
        : 'Sign in to stay connected with your team.',
    child: Form(
      key: form,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: email,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              validator: (value) =>
                  RegExp(
                    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                  ).hasMatch(value?.trim() ?? '')
                  ? null
                  : 'Enter a valid email address.',
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon: Icon(Icons.mail_outline),
                errorMaxLines: 2,
              ),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: password,
              enabled: !busy,
              obscureText: !showPassword,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              autofillHints: [
                register ? AutofillHints.newPassword : AutofillHints.password,
              ],
              validator: (value) => (value ?? '').isEmpty
                  ? 'Enter your password.'
                  : register && value!.length < 6
                  ? 'Use at least 6 characters.'
                  : null,
              onFieldSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                errorMaxLines: 2,
                suffixIcon: IconButton(
                  tooltip: showPassword ? 'Hide password' : 'Show password',
                  onPressed: () => setState(() => showPassword = !showPassword),
                  icon: Icon(
                    showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            if (!register)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : resetPassword,
                  child: const Text('Forgot password?'),
                ),
              ),
            if (error != null) ChatNotice(error!),
            if (notice != null) ChatNotice(notice!, success: true),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(register ? 'Create account' : 'Sign in'),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      register = !register;
                      error = null;
                      notice = null;
                    }),
              child: Text(
                register
                    ? 'Already have an account? Sign in'
                    : 'New to TMS Connect? Create an account',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class AccountLoader extends StatefulWidget {
  const AccountLoader({super.key});
  @override
  State<AccountLoader> createState() => _AccountLoaderState();
}

class _AccountLoaderState extends State<AccountLoader> {
  final api = Api();
  final name = TextEditingController(), username = TextEditingController();
  final form = GlobalKey<FormState>();
  ChatState? chat;
  bool profileNeeded = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool save = false}) async {
    if (save && !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = Map<String, dynamic>.from(
        save
            ? await api.put('/me', {
                'name': name.text,
                'username': username.text,
              })
            : await api.get('/me'),
      );
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      chat = ChatState(api, data, prefs);
      await chat!.start();
    } catch (e) {
      if (!mounted) return;
      if (Api.error(e).contains('Complete your profile')) {
        profileNeeded = true;
      } else {
        error = Api.error(e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    chat?.dispose();
    name.dispose();
    username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (chat != null) return ChatHome(chat: chat!);
    return AccountSurface(
      title: profileNeeded ? 'Make it yours' : 'Opening your messages',
      subtitle: profileNeeded
          ? 'Help your team recognize you in every conversation.'
          : 'Connecting to your conversations and team.',
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (profileNeeded) ...[
              Center(
                child: Avatar(
                  name.text.isEmpty ? 'You' : name.text,
                  radius: 32,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: name,
                enabled: !busy,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                validator: (value) => (value?.trim().isEmpty ?? true)
                    ? 'Enter your display name.'
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  prefixIcon: Icon(Icons.person_outline),
                  errorMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: username,
                enabled: !busy,
                maxLength: 32,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                validator: (value) =>
                    RegExp(
                      r'^[a-z0-9_]{3,32}$',
                    ).hasMatch(value?.trim().toLowerCase() ?? '')
                    ? null
                    : 'Use 3–32 letters, numbers or underscores.',
                onFieldSubmitted: (_) {
                  if (!busy) load(save: true);
                },
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixText: '@',
                  helperText: 'Your permanent name for @mentions.',
                  helperMaxLines: 2,
                  errorMaxLines: 2,
                ),
              ),
            ],
            if (error != null) ChatNotice(error!),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              FilledButton(
                onPressed: () => load(save: profileNeeded),
                child: Text(profileNeeded ? 'Start messaging' : 'Try again'),
              ),
            TextButton(
              onPressed: busy ? null : () => FirebaseAuth.instance.signOut(),
              child: const Text('Use another account'),
            ),
          ],
        ),
      ),
    );
  }
}
