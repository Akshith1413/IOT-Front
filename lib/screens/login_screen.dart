import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';
import '../services/auth_service.dart';
import 'register_screen.dart';
import '../main.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  String email = '';
  String password = '';
  String error = '';
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: ParticleBackground(
        particleCount: 55,
        baseColor: AppColors.auroraTeal,
        accentColor: AppColors.plasmaViolet,
        connectionDistance: 130,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.all(32.0),
                  decoration: AppDecorations.glassCard(
                    glowColor: AppColors.auroraTeal,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Icon
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                AppColors.auroraTeal.withValues(alpha: 0.25),
                                AppColors.plasmaViolet.withValues(alpha: 0.08),
                              ],
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_outline_rounded,
                            size: 56,
                            color: AppColors.auroraTeal,
                          ),
                        ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack),

                        const SizedBox(height: 28),

                        const Text(
                          'Welcome Back',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.heading,
                        ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.3, end: 0),

                        const SizedBox(height: 8),
                        const Text(
                          'Sign in to CardioSync',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.subheading,
                        ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.3, end: 0),

                        const SizedBox(height: 48),

                        _buildTextField(
                          label: 'Email Address',
                          icon: Icons.email_outlined,
                          onChanged: (val) => email = val,
                          validator: (val) =>
                              val!.isEmpty ? 'Enter an email' : null,
                        ).animate().fadeIn(delay: 400.ms).slideX(begin: -0.2, end: 0),

                        const SizedBox(height: 16),

                        _buildTextField(
                          label: 'Password',
                          icon: Icons.lock_outline,
                          obscureText: true,
                          onChanged: (val) => password = val,
                          validator: (val) =>
                              val!.length < 6 ? 'Password must be 6+ chars' : null,
                        ).animate().fadeIn(delay: 500.ms).slideX(begin: -0.2, end: 0),

                        const SizedBox(height: 24),

                        if (error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: Text(
                              error,
                              style: const TextStyle(
                                color: AppColors.stellarRose,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ).animate().fadeIn(),

                        // Sign In Button
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              colors: [AppColors.auroraTeal, Color(0xFF00C9A7)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.auroraTeal.withValues(alpha: 0.4),
                                blurRadius: 20,
                                spreadRadius: -4,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
                            onPressed: loading
                                ? null
                                : () async {
                                    if (_formKey.currentState!.validate()) {
                                      setState(() => loading = true);
                                      try {
                                        await context
                                            .read<AuthService>()
                                            .signInWithEmailAndPassword(
                                                email, password);
                                        if (context.mounted) {
                                          Navigator.of(context)
                                              .pushAndRemoveUntil(
                                            MaterialPageRoute(
                                                builder: (context) =>
                                                    const AuthWrapper()),
                                            (route) => false,
                                          );
                                        }
                                      } catch (e) {
                                        setState(() {
                                          error =
                                              'Could not sign in with those credentials';
                                          loading = false;
                                        });
                                      }
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: AppColors.deepSpace,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                            ),
                            child: loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      color: AppColors.deepSpace,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    'Sign In',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ).animate().fadeIn(delay: 600.ms).scale(),

                        const SizedBox(height: 24),

                        TextButton(
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const RegisterScreen()),
                            );
                          },
                          child: RichText(
                            text: const TextSpan(
                              text: "Don't have an account? ",
                              style: AppTextStyles.subheading,
                              children: [
                                TextSpan(
                                  text: 'Register',
                                  style: TextStyle(
                                    color: AppColors.plasmaViolet,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ).animate().fadeIn(delay: 700.ms),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required IconData icon,
    required Function(String) onChanged,
    String? Function(String?)? validator,
    bool obscureText = false,
  }) {
    return TextFormField(
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: AppColors.textSecondary.withValues(alpha: 0.8),
          fontSize: 14,
        ),
        prefixIcon: Icon(icon, color: AppColors.auroraTeal.withValues(alpha: 0.8), size: 22),
        filled: true,
        fillColor: AppColors.deepSpace.withValues(alpha: 0.6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: AppColors.cardBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.auroraTeal, width: 1.5),
        ),
        errorStyle: const TextStyle(color: AppColors.stellarRose),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      obscureText: obscureText,
      onChanged: onChanged,
      validator: validator,
      cursorColor: AppColors.auroraTeal,
    );
  }
}
