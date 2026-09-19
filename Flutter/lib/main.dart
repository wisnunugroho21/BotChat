import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat/api.dart';
import 'chat/chat_state.dart';
import 'chat/home.dart';
import 'chat/theme.dart';

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
  bool register = false, busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
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

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.forum_rounded,
                  color: ChatColors.blue,
                  size: 56,
                ),
                const SizedBox(height: 20),
                const Text(
                  'TMS CONNECT',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ChatColors.blue,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  register ? 'Create your account' : 'Welcome to Messages',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Stay connected with your team.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ChatColors.muted),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                  onSubmitted: (_) {
                    if (!busy) submit();
                  },
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(
                    busy
                        ? 'Please wait…'
                        : register
                        ? 'Create account'
                        : 'Sign in',
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => register = !register),
                  child: Text(
                    register
                        ? 'Already have an account? Sign in'
                        : 'Create an account',
                  ),
                ),
                if (!register)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            try {
                              await FirebaseAuth.instance
                                  .sendPasswordResetEmail(
                                    email: email.text.trim(),
                                  );
                              if (mounted) {
                                setState(
                                  () => error =
                                      'If this account exists, a reset email will arrive shortly.',
                                );
                              }
                            } catch (e) {
                              if (mounted) setState(() => error = Api.error(e));
                            }
                          },
                    child: const Text('Forgot password?'),
                  ),
              ],
            ),
          ),
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
  ChatState? chat;
  bool profileNeeded = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool save = false}) async {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('TMS Connect'),
        actions: [
          TextButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (profileNeeded) ...[
                  const Text(
                    'Complete your profile',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: name,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                  ),
                  TextField(
                    controller: username,
                    maxLength: 32,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      helperText: 'Used for @mentions. Cannot be changed.',
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (busy)
                  const CircularProgressIndicator()
                else
                  FilledButton(
                    onPressed: () => load(save: profileNeeded),
                    child: Text(profileNeeded ? 'Start messaging' : 'Retry'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
