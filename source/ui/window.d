module ui.window;

import std.concurrency;
import std.parallelism;
import std.stdio;
import std.variant;
import core.thread;

import gdk.FrameClock;
import gdk.Keysyms;
import gio.ThemedIcon;
import gtk.Box;
import gtk.Button;
import gtk.Container;
import gtk.HeaderBar;
import gtk.IconTheme;
import gtk.Image;
import gtk.Label;
import gtk.Main;
import gtk.MainWindow;
import gtk.Widget;

import game;
import networking;
import player;
import ui.boardWidget;
import ui.networkWidget;
import ui.newgamedialog;
import utils.addtickcallback;
import ai.gnubg;

/**
 * The MainWindow of the backgammon game. Also acts as a high level controller
 * for receiving button presses, network events etc.
 */
class BackgammonWindow : MainWindow {
    private:
    HeaderBar header;
    Button newGameBtn;
    Button inetGameBtn;

    BackgammonBoard backgammonBoard;
    NetworkWidget networkingWidget;
    NewGameDialog newGameDialog;
    Thread netThread;

    GameState gameState;

    Task!(gnubgGetTurn, GameState, GnubgEvalContext) *aiGetTurn;
    bool isWaitingForAnimation = false;
    Turn remoteResult;

    /**
     * Create a new backgammon board window
     */
    public this() {
        super("Backgammon");

        header = new HeaderBar();
        header.setTitle("Backgammon");
        header.setShowCloseButton(true);
        this.setTitlebar(header);

        newGameBtn = new Button("New Game");
        newGameBtn.addOnClicked((Button b) => openNewGameDialog() );
        header.packStart(newGameBtn);

        // Internet game
        inetGameBtn = new Button();
        auto icon = new ThemedIcon("network-server-symbolic");
        auto inetImg = new Image();
        inetImg.setFromGicon(icon, IconSize.BUTTON);
        inetGameBtn.add(inetImg);
        inetGameBtn.addOnClicked((Button b) {
            netThread = new NetworkingThread().start();
            networkingWidget = new NetworkWidget(this);
        });
        header.packStart(inetGameBtn);

        // // Move buttons
        auto undoMoveBtn = new Button();
        icon = new ThemedIcon("edit-undo-symbolic");
        inetImg = new Image();
        inetImg.setFromGicon(icon, IconSize.BUTTON);
        undoMoveBtn.add(inetImg);
        undoMoveBtn.addOnClicked((Button b) {
            backgammonBoard.undoSelectedMove();
        });
        undoMoveBtn.setSensitive(false);

        auto finishMoveBtn = new Button("Finish");
        finishMoveBtn.addOnClicked((Button b) {
            backgammonBoard.finishTurn();
        });
        finishMoveBtn.setSensitive(false);
        header.packEnd(finishMoveBtn);
        header.packEnd(undoMoveBtn);

        // Keyboard shortcuts
        this.addOnKeyPress(&onKeyPress);

        // Game board
        backgammonBoard = new BackgammonBoard();
        backgammonBoard.onChangePotentialMovements.connect(() {
            undoMoveBtn.setSensitive(!!backgammonBoard.getSelectedMoves().length);

            finishMoveBtn.setSensitive(false);
            if (gameState.turnState == TurnState.MoveSelection) {
                try {
                    backgammonBoard.getGameState().validateTurn(backgammonBoard.getSelectedMoves());
                    finishMoveBtn.setSensitive(true);
                } catch (Exception e) {
                    finishMoveBtn.setSensitive(false);
                }
            }
        });

        this.add(backgammonBoard);
        this.setDefaultSize(800, 600);

        this.addTickCallback(&handleThreadMessages);


        // AI example
        // Variant aiConfig = gnubgDefaultEvalContexts[0];
        // auto gs = new GameState(
        //     PlayerMeta("AI 1", "gnubg", PlayerType.AI, aiConfig),
        //     PlayerMeta("AI 1", "gnubg", PlayerType.AI, aiConfig)
        // );
        // setGameState(gs);
        // gs.newGame();

        // Taking a piece and moving on
        auto gs = new GameState();
        setGameState(gs);
        gs.newGame();
        gs.points[5] = Point(Player.P2, 1);
        backgammonBoard.selectMove(PipMovement(PipMoveType.Movement, 6, 5));
        backgammonBoard.selectMove(PipMovement(PipMoveType.Movement, 5, 3));
    }

    /**
     * Keyboard Shortcuts
     */
    bool onKeyPress(GdkEventKey* g, Widget w) {
        // If CTRL key pressed
        if (g.state & ModifierType.CONTROL_MASK) {
            switch(g.keyval) {
            case Keysyms.GDK_n:
                this.openNewGameDialog();
                break;
            default: break;
            }
        }

        return false;
    }

    /**
     * Open the new game dialog
     */
    void openNewGameDialog() {
        // Create new game
        newGameDialog = new NewGameDialog(this);
        newGameDialog.onCreateNewGame.connect((GameState gs) {
            setGameState(gs);
            gs.newGame();
            newGameDialog.destroy();
            newGameDialog = null;
        });
    }

    void setGameState(GameState gs) {
        this.aiGetTurn = null;

        backgammonBoard.setGameState(gs);
        this.gameState = gs;

        // Link up gamestate to various things
        // How are dice rolls handled?
        gs.onBeginTurn.connect((GameState _gs, Player p) {
            header.setSubtitle(p == Player.P1 ? "Black to play" : "White to play");
            _gs.rollDice();

            // Who is handling this turn?
            if (_gs.players[p].type == PlayerType.AI) {
                aiGetTurn = task!gnubgGetTurn(_gs,
                    *_gs.players[p].config.peek!GnubgEvalContext);
                aiGetTurn.executeInNewThread();
            }
        });
    }

    bool handleThreadMessages(Widget w, FrameClock f) {
        import networking.messages;

        if (isWaitingForAnimation && !backgammonBoard.isAnimating) {
            backgammonBoard.finishTurn();
            isWaitingForAnimation = false;
        }

        if (aiGetTurn && aiGetTurn.done) {
            remoteResult = aiGetTurn.yieldForce;
            aiGetTurn = null;
            foreach (move; remoteResult) {
                backgammonBoard.selectMove(move);
            }
            isWaitingForAnimation = true;
        }

        if (netThread && netThread.isRunning) {
            receiveTimeout(5.msecs,
                (NetworkThreadStatus status) {
                    this.networkingWidget.statusMessage.setText(status.message);
                },
                (NetworkThreadError error) {
                    this.networkingWidget.statusMessage.setText(error.message);
                    this.networkingWidget.spinner.stop();
                },
                (NetworkBeginGame game) {
                    this.networkingWidget.destroy();
                },
                (NetworkNewDiceRoll diceRoll) {
                    this.backgammonBoard.getGameState.rollDice(diceRoll.dice1, diceRoll.dice2);
                }
            );
        }
        return true;
    }

    public mixin AddTickCallback;
}
