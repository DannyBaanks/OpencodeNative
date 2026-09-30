package dev.iyscode.movil

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.lifecycleScope
import dev.iyscode.movil.gus.ModelState
import dev.iyscode.movil.ui.IsyCodeRoot
import dev.iyscode.movil.ui.IysTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val viewModel: GusViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { IysTheme { IsyCodeRoot(viewModel) } }
        // Keep the screen on while a model downloads: the transfer lives in
        // the app process and would pause if the phone went to sleep.
        lifecycleScope.launch {
            viewModel.store.states.collect { states ->
                if (states.values.any { it is ModelState.Downloading }) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshBudget()
        viewModel.reloadReports()
    }
}
